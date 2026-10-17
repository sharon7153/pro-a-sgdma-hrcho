// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2023-2025 Analog Devices, Inc. All rights reserved.
//
// In this HDL repository, there are many different and unique modules, consisting
// of various HDL (Verilog or VHDL) components. The individual modules are
// developed independently, and may be accompanied by separate and unique license
// terms.
//
// The user should read each of these license terms, and understand the
// freedoms and responsibilities that he or she has by using this source/core.
//
// This core is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//
//   1. The GNU General Public License version 2 as published by the
//      Free Software Foundation, which can be found in the top level directory
//      of this repository (LICENSE_GPL2), and also online at:
//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
//
// OR
//
//   2. An ADI specific BSD license, which can be found in the top level directory
//      of this repository (LICENSE_ADIBSD), and also on-line at:
//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
//      This will allow to generate bit files and not release the source code,
//      as long as it attaches to an ADI device.
//
// ***************************************************************************
// ***************************************************************************

// Modified for sg_dma (2026-10-17): reduced to the SG, AXI-MM -> AXI-MM,
// single-clock configuration. Unused interfaces, parameters and
// generate branches of the original ADI module were removed.
// ***************************************************************************

`timescale 1ns/100ps

// Scatter-Gather engine: fetches 48-byte hardware descriptors over m_axi
// (6 x 64-bit beats) and hands {dest, src, length} to the transfer path.
//
//   +0x00 [63:32] id  [1:0] flags (bit0 LAST, bit1 EOT_IRQ)
//   +0x08 dest address
//   +0x10 src address
//   +0x18 next descriptor address
//   +0x20 [63:32] x_length (bytes - 1)   [31:0] unused (2D y_length)
//   +0x28 unused (2D strides)
module dmac_sg #(
  parameter DMA_AXI_ADDR_WIDTH = 32,
  parameter DMA_LENGTH_WIDTH = 24,
  parameter BYTES_PER_BEAT_WIDTH = 3,     // data path (src/dest) address alignment
  parameter [3:0] AXI_AXCACHE = 4'b0000,
  parameter [2:0] AXI_AXPROT = 3'b000
) (
  input clk,
  input resetn,

  input sg_enable,
  output sg_enabled,

  input req_in_valid,
  output req_in_ready,

  output req_out_valid,
  input req_out_ready,

  output resp_out_eot,
  input resp_in_valid,

  input [DMA_AXI_ADDR_WIDTH-1:3] req_desc_address,

  output [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] out_dest_address,
  output [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] out_src_address,
  output [DMA_LENGTH_WIDTH-1:0] out_x_length,
  output [31:0] resp_out_id,

  // Read address
  input                            m_axi_arready,
  output                           m_axi_arvalid,
  output [DMA_AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
  output [7:0]                     m_axi_arlen,
  output [ 2:0]                    m_axi_arsize,
  output [ 1:0]                    m_axi_arburst,
  output [ 2:0]                    m_axi_arprot,
  output [ 3:0]                    m_axi_arcache,

  // Read data (64-bit, RRESP is not checked)
  input  [63:0]                    m_axi_rdata,
  input                            m_axi_rlast,
  output                           m_axi_rready,
  input                            m_axi_rvalid
);

  localparam STATE_IDLE = 0;
  localparam STATE_SEND_ADDR = 1;
  localparam STATE_RECV_DESC = 2;
  localparam STATE_DESC_READY = 3;

  localparam MASK_LAST_HWDESC = 1 << 0;
  localparam MASK_EOT_IRQ = 1 << 1;

  localparam DMA_ADDRESS_WIDTH = DMA_AXI_ADDR_WIDTH - BYTES_PER_BEAT_WIDTH;
  localparam DMA_ADDRESS_WIDTH_SG = DMA_AXI_ADDR_WIDTH - 3;
  localparam DMA_DESCRIPTOR_WIDTH = 2*DMA_ADDRESS_WIDTH + DMA_LENGTH_WIDTH;

  wire [DMA_AXI_ADDR_WIDTH-1:3] first_desc_address;
  reg [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] dest_addr;
  reg [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] src_addr;
  reg [DMA_AXI_ADDR_WIDTH-1:3] next_desc_addr;
  reg [DMA_LENGTH_WIDTH-1:0] x_length;

  reg [1:0] hwdesc_state;
  reg [2:0] hwdesc_counter;
  reg [1:0] hwdesc_flags;
  reg [31:0] hwdesc_id;

  wire sg_in_valid;
  wire sg_in_ready;
  wire sg_out_valid;
  wire sg_out_ready;
  wire fetch_valid;
  wire fetch_ready;
  wire fifo_in_valid;
  wire fifo_in_ready;
  wire [32:0] fifo_in_data;
  wire [32:0] fifo_out_data;

  assign sg_enabled = sg_enable | ~sg_in_ready;

  assign sg_in_ready = hwdesc_state == STATE_IDLE;
  assign fetch_valid = hwdesc_state == STATE_DESC_READY;
  assign m_axi_arvalid = hwdesc_state == STATE_SEND_ADDR;
  assign m_axi_rready = hwdesc_state == STATE_RECV_DESC;

  // One INCR burst of 6 x 8 bytes per descriptor
  assign m_axi_arsize  = 3'h3;
  assign m_axi_arburst = 2'h1;
  assign m_axi_arprot  = AXI_AXPROT;
  assign m_axi_arcache = AXI_AXCACHE;
  assign m_axi_arlen   = 'h5;
  assign m_axi_araddr  = {next_desc_addr, 3'b000};

  // First descriptor address from SG_ADDRESS
  util_axis_fifo #(
    .DATA_WIDTH(DMA_ADDRESS_WIDTH_SG),
    .ADDRESS_WIDTH(0)
  ) i_sg_addr_fifo (
    .clk(clk),
    .resetn(resetn),
    .s_axis_valid(req_in_valid),
    .s_axis_ready(req_in_ready),
    .s_axis_data(req_desc_address),
    .m_axis_valid(sg_in_valid),
    .m_axis_ready(sg_in_ready),
    .m_axis_data(first_desc_address));

  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      hwdesc_counter <= 'h0;
    end else if (m_axi_rvalid) begin
      hwdesc_counter <= hwdesc_counter + 1'b1;
    end else if (hwdesc_state == STATE_DESC_READY) begin
      hwdesc_counter <= 'h0;
    end
  end

  // Read the descriptor data
  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      hwdesc_flags <= 'h00;
      hwdesc_id <= 'h00;
      dest_addr <= 'h00;
      src_addr <= 'h00;
      next_desc_addr <= 'h00;
      x_length <= 'h00;
    end else begin
      if (sg_in_valid && sg_in_ready) begin
        next_desc_addr <= first_desc_address;
      end
      if (m_axi_rvalid) begin
        case (hwdesc_counter)
        0: begin
          hwdesc_id <= m_axi_rdata[63:32];
          hwdesc_flags <= m_axi_rdata[1:0];
          end
        1: dest_addr <= m_axi_rdata[DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH];
        2: src_addr <= m_axi_rdata[DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH];
        3: next_desc_addr <= m_axi_rdata[DMA_AXI_ADDR_WIDTH-1:3];
        4: x_length <= m_axi_rdata[63:32];
        endcase
      end
    end
  end

  // Descriptor FSM
  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      hwdesc_state <= STATE_IDLE;
    end else begin
      case (hwdesc_state)
        STATE_IDLE: begin
          if (sg_in_valid == 1'b1 && sg_enable == 1'b1) begin
            hwdesc_state <= STATE_SEND_ADDR;
          end
          end

        STATE_SEND_ADDR: begin
          if (m_axi_arready) begin
            hwdesc_state <= STATE_RECV_DESC;
          end
          end

        STATE_RECV_DESC: begin
          if (m_axi_rvalid == 1'b1 && m_axi_rlast == 1'b1) begin
            hwdesc_state <= STATE_DESC_READY;
          end
          end

        STATE_DESC_READY: begin
          if (sg_enable == 1'b0) begin
              hwdesc_state <= STATE_IDLE;
          end else if (fetch_ready == 1'b1) begin
            if (hwdesc_flags & MASK_LAST_HWDESC) begin
              hwdesc_state <= STATE_IDLE;
            end else begin
              hwdesc_state <= STATE_SEND_ADDR;
            end
          end
          end
      endcase
    end
  end

  // Parsed descriptor -> transfer path
  util_axis_fifo #(
    .DATA_WIDTH(DMA_DESCRIPTOR_WIDTH),
    .ADDRESS_WIDTH(0)
  ) i_sg_desc_fifo (
    .clk(clk),
    .resetn(resetn),
    .s_axis_valid(sg_out_valid),
    .s_axis_ready(sg_out_ready),
    .s_axis_data({
      dest_addr,
      src_addr,
      x_length}),
    .m_axis_valid(req_out_valid),
    .m_axis_ready(req_out_ready),
    .m_axis_data({
      out_dest_address,
      out_src_address,
      out_x_length}));

  splitter #(
    .NUM_M(2)
  ) i_req_splitter (
    .clk(clk),
    .resetn(resetn),
    .s_valid(fetch_valid),
    .s_ready(fetch_ready),
    .m_valid({
      sg_out_valid,
      fifo_in_valid}),
    .m_ready({
      sg_out_ready,
      fifo_in_ready}));

  assign fifo_in_data = {hwdesc_flags & MASK_EOT_IRQ ? 1'b1 : 1'b0, hwdesc_id};
  assign resp_out_eot = fifo_out_data[32];
  assign resp_out_id = fifo_out_data[31:0];

  // Save the descriptor IDs and the EOT_IRQ flag; pop one entry per completed
  // descriptor (DESCRIPTOR_ID register shows the head)
  util_axis_fifo #(
    .DATA_WIDTH(33),
    .ADDRESS_WIDTH(2)
  ) i_fifo (
    .clk(clk),
    .resetn(resetn),
    .s_axis_valid(fifo_in_valid),
    .s_axis_ready(fifo_in_ready),
    .s_axis_data(fifo_in_data),
    .m_axis_valid(),
    .m_axis_ready(resp_in_valid),
    .m_axis_data(fifo_out_data));

endmodule
