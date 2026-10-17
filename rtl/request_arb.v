// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2025 Analog Devices, Inc. All rights reserved.
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

// Data mover: AXI-MM source -> burst memory -> AXI-MM destination.
module request_arb #(
  parameter DMA_DATA_WIDTH = 64,
  parameter DMA_LENGTH_WIDTH = 24,
  parameter BYTES_PER_BEAT_WIDTH = $clog2(DMA_DATA_WIDTH/8),
  parameter DMA_AXI_ADDR_WIDTH = 32,
  parameter MAX_BYTES_PER_BURST = 128,
  parameter BYTES_PER_BURST_WIDTH = 7,
  parameter ID_WIDTH = 4,
  parameter [3:0] AXI_AXCACHE = 4'b0000,
  parameter [2:0] AXI_AXPROT = 3'b000
) (
  input clk,
  input resetn,

  input req_valid,
  output req_ready,
  input [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] req_dest_address,
  input [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] req_src_address,
  input [DMA_LENGTH_WIDTH-1:0] req_length,

  output eot,
  output [BYTES_PER_BURST_WIDTH-1:0] measured_burst_length,
  output response_valid,
  input response_ready,

  input req_enable,

  input dest_enable,
  output dest_enabled,
  input src_enable,
  output src_enabled,

  // Write address
  output [DMA_AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
  output [7:0]                        m_axi_awlen,
  output [ 2:0]                       m_axi_awsize,
  output [ 1:0]                       m_axi_awburst,
  output [ 2:0]                       m_axi_awprot,
  output [ 3:0]                       m_axi_awcache,
  output                              m_axi_awvalid,
  input                               m_axi_awready,

  // Write data
  output [DMA_DATA_WIDTH-1:0]         m_axi_wdata,
  output [(DMA_DATA_WIDTH/8)-1:0]     m_axi_wstrb,
  input                               m_axi_wready,
  output                              m_axi_wvalid,
  output                              m_axi_wlast,

  // Write response
  input                               m_axi_bvalid,
  output                              m_axi_bready,

  // Read address
  input                               m_axi_arready,
  output                              m_axi_arvalid,
  output [DMA_AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
  output [7:0]                        m_axi_arlen,
  output [ 2:0]                       m_axi_arsize,
  output [ 1:0]                       m_axi_arburst,
  output [ 2:0]                       m_axi_arprot,
  output [ 3:0]                       m_axi_arcache,

  // Read data
  input  [DMA_DATA_WIDTH-1:0]         m_axi_rdata,
  output                              m_axi_rready,
  input                               m_axi_rvalid,
  input                               m_axi_rlast,

  // Burst IDs (debug registers)
  output [ID_WIDTH-1:0]               dbg_dest_request_id,
  output [ID_WIDTH-1:0]               dbg_dest_address_id,
  output [ID_WIDTH-1:0]               dbg_dest_data_id,
  output [ID_WIDTH-1:0]               dbg_dest_response_id,
  output [ID_WIDTH-1:0]               dbg_src_request_id,
  output [ID_WIDTH-1:0]               dbg_src_address_id,
  output [ID_WIDTH-1:0]               dbg_src_data_id,
  output [ID_WIDTH-1:0]               dbg_src_response_id
);

  localparam DMA_ADDRESS_WIDTH = DMA_AXI_ADDR_WIDTH - BYTES_PER_BEAT_WIDTH;

  // Bytes per burst and bytes per beat are the same on both sides
  localparam BEATS_PER_BURST_WIDTH = BYTES_PER_BURST_WIDTH - BYTES_PER_BEAT_WIDTH;
  localparam BURSTS_PER_TRANSFER_WIDTH = DMA_LENGTH_WIDTH - BYTES_PER_BURST_WIDTH;

  // End-of-transfer flag per burst ID, written by the request side and the
  // source side respectively
  reg eot_mem_src[0:2**ID_WIDTH-1];
  reg eot_mem_dest[0:2**ID_WIDTH-1];
  wire request_eot;
  wire source_eot;

  wire [ID_WIDTH-1:0] request_id;
  wire [ID_WIDTH-1:0] source_id;
  wire [ID_WIDTH-1:0] response_id;

  wire req_gen_valid;
  wire req_gen_ready;
  wire req_src_valid;
  wire req_src_ready;

  wire dest_req_valid;
  wire dest_req_ready;
  wire [DMA_ADDRESS_WIDTH-1:0] dest_req_dest_address;

  wire dest_response_valid;
  wire dest_response_ready;
  wire dest_response_resp_eot;
  wire [BYTES_PER_BURST_WIDTH-1:0] dest_response_data_burst_length;

  wire [ID_WIDTH-1:0] dest_request_id;
  wire [ID_WIDTH-1:0] dest_data_request_id;
  wire [ID_WIDTH-1:0] dest_data_response_id;
  wire [ID_WIDTH-1:0] dest_response_id;
  wire [ID_WIDTH-1:0] dest_address_id;

  wire dest_valid;
  wire dest_ready;
  wire [DMA_DATA_WIDTH-1:0] dest_data;
  wire [DMA_DATA_WIDTH/8-1:0] dest_strb;
  wire dest_last;

  wire src_req_spltr_valid;
  wire src_req_spltr_ready;
  wire src_req_valid;
  wire src_req_ready;
  wire [DMA_ADDRESS_WIDTH-1:0] src_req_dest_address;
  wire [DMA_ADDRESS_WIDTH-1:0] src_req_src_address;
  wire [BEATS_PER_BURST_WIDTH-1:0] src_req_last_burst_length;
  wire [BYTES_PER_BEAT_WIDTH-1:0] src_req_last_beat_bytes;

  reg [DMA_ADDRESS_WIDTH-1:0] src_req_dest_address_cur = 'h0;

  wire [ID_WIDTH-1:0] src_request_id;
  reg [ID_WIDTH-1:0] src_throttled_request_id;
  wire [ID_WIDTH-1:0] src_data_request_id;
  wire [ID_WIDTH-1:0] src_response_id;
  wire [ID_WIDTH-1:0] src_data_id;
  wire [ID_WIDTH-1:0] src_address_id;

  wire src_valid;
  wire [DMA_DATA_WIDTH-1:0] src_data;
  wire [BYTES_PER_BEAT_WIDTH-1:0] src_valid_bytes;
  wire src_last;

  wire                             src_bl_valid;
  wire                             src_bl_ready;
  wire [BEATS_PER_BURST_WIDTH-1:0] src_burst_length;
  wire                             dest_bl_valid;
  wire                             dest_bl_ready;
  wire [BEATS_PER_BURST_WIDTH-1:0] dest_burst_length;

  wire [BYTES_PER_BURST_WIDTH-1:0] dest_burst_info_length;
  wire [ID_WIDTH-1:0] dest_burst_info_id;
  wire                dest_burst_info_write;

  reg src_dest_valid_hs = 1'b0;
  wire src_dest_ready_hs;

  assign dbg_dest_request_id = dest_request_id;
  assign dbg_dest_address_id = dest_address_id;
  assign dbg_dest_data_id = dest_data_response_id;
  assign dbg_dest_response_id = dest_response_id;
  assign dbg_src_request_id = src_request_id;
  assign dbg_src_address_id = src_address_id;
  assign dbg_src_data_id = src_data_id;
  assign dbg_src_response_id = src_response_id;

  // Single clock domain: the request side IDs are used directly
  assign src_request_id = request_id;
  assign response_id = dest_response_id;

  assign source_id = src_address_id;
  assign source_eot = eot_mem_src[src_address_id];

  always @(posedge clk)
  begin
    eot_mem_src[request_id] <= request_eot;
  end

  always @(posedge clk)
  begin
    eot_mem_dest[source_id] <= source_eot;
  end

  // --------------------------------------------------------------------------
  // Destination: AXI-MM write
  // --------------------------------------------------------------------------
  wire dest_address_eot = eot_mem_dest[dest_address_id];
  wire dest_response_eot = eot_mem_dest[dest_response_id];

  assign dest_data_request_id = dest_address_id;

  dest_axi_mm #(
    .ID_WIDTH(ID_WIDTH),
    .DMA_DATA_WIDTH(DMA_DATA_WIDTH),
    .DMA_ADDR_WIDTH(DMA_AXI_ADDR_WIDTH),
    .BEATS_PER_BURST_WIDTH(BEATS_PER_BURST_WIDTH),
    .BYTES_PER_BEAT_WIDTH(BYTES_PER_BEAT_WIDTH),
    .BYTES_PER_BURST_WIDTH(BYTES_PER_BURST_WIDTH),
    .AXI_AXCACHE(AXI_AXCACHE),
    .AXI_AXPROT(AXI_AXPROT)
  ) i_dest_dma_mm (
    .m_axi_aclk(clk),
    .m_axi_aresetn(resetn),

    .enable(dest_enable),
    .enabled(dest_enabled),

    .req_valid(dest_req_valid),
    .req_ready(dest_req_ready),
    .req_address(dest_req_dest_address),

    .bl_valid(dest_bl_valid),
    .bl_ready(dest_bl_ready),
    .measured_last_burst_length(dest_burst_length),

    .response_valid(dest_response_valid),
    .response_ready(dest_response_ready),
    .response_resp_eot(dest_response_resp_eot),
    .response_data_burst_length(dest_response_data_burst_length),

    .request_id(dest_request_id),
    .response_id(dest_response_id),

    .address_id(dest_address_id),

    .address_eot(dest_address_eot),
    .response_eot(dest_response_eot),

    .fifo_valid(dest_valid),
    .fifo_ready(dest_ready),
    .fifo_data(dest_data),
    .fifo_strb(dest_strb),
    .fifo_last(dest_last),

    .dest_burst_info_length(dest_burst_info_length),
    .dest_burst_info_id(dest_burst_info_id),
    .dest_burst_info_write(dest_burst_info_write),

    .m_axi_awready(m_axi_awready),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst),
    .m_axi_awprot(m_axi_awprot),
    .m_axi_awcache(m_axi_awcache),
    .m_axi_wready(m_axi_wready),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wlast(m_axi_wlast),

    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready));

  // Last-burst length, source side -> destination side
  util_axis_fifo #(
    .DATA_WIDTH(BEATS_PER_BURST_WIDTH),
    .ADDRESS_WIDTH(0)
  ) i_src_dest_bl_fifo (
    .clk(clk),
    .resetn(resetn),
    .s_axis_valid(src_bl_valid),
    .s_axis_ready(src_bl_ready),
    .s_axis_data(src_burst_length),
    .m_axis_valid(dest_bl_valid),
    .m_axis_ready(dest_bl_ready),
    .m_axis_data(dest_burst_length));

  // --------------------------------------------------------------------------
  // Source: AXI-MM read
  // --------------------------------------------------------------------------
  src_axi_mm #(
    .ID_WIDTH(ID_WIDTH),
    .DMA_DATA_WIDTH(DMA_DATA_WIDTH),
    .DMA_ADDR_WIDTH(DMA_AXI_ADDR_WIDTH),
    .BEATS_PER_BURST_WIDTH(BEATS_PER_BURST_WIDTH),
    .BYTES_PER_BEAT_WIDTH(BYTES_PER_BEAT_WIDTH),
    .AXI_AXCACHE(AXI_AXCACHE),
    .AXI_AXPROT(AXI_AXPROT)
  ) i_src_dma_mm (
    .m_axi_aclk(clk),
    .m_axi_aresetn(resetn),

    .enable(src_enable),
    .enabled(src_enabled),

    .req_valid(src_req_valid),
    .req_ready(src_req_ready),
    .req_address(src_req_src_address),
    .req_last_burst_length(src_req_last_burst_length),
    .req_last_beat_bytes(src_req_last_beat_bytes),

    .bl_valid(src_bl_valid),
    .bl_ready(src_bl_ready),
    .measured_last_burst_length(src_burst_length),

    .request_id(src_throttled_request_id),
    .response_id(src_response_id),
    .address_id(src_address_id),
    .data_id(src_data_id),

    .address_eot(source_eot),

    .fifo_valid(src_valid),
    .fifo_data(src_data),
    .fifo_valid_bytes(src_valid_bytes),
    .fifo_last(src_last),

    .m_axi_arready(m_axi_arready),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize),
    .m_axi_arburst(m_axi_arburst),
    .m_axi_arprot(m_axi_arprot),
    .m_axi_arcache(m_axi_arcache),

    .m_axi_rready(m_axi_rready),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rlast(m_axi_rlast));

  `include "inc_id.vh"

  function compare_id;
    input [ID_WIDTH-1:0] a;
    input [ID_WIDTH-1:0] b;
    begin
      compare_id = a[ID_WIDTH-1] == b[ID_WIDTH-1];
      if (ID_WIDTH >= 2) begin
        if (a[ID_WIDTH-2] == b[ID_WIDTH-2]) begin
          compare_id = 1'b1;
        end
      end
      if (ID_WIDTH >= 3) begin
        if (a[ID_WIDTH-3:0] != b[ID_WIDTH-3:0]) begin
          compare_id = 1'b1;
        end
      end
    end
  endfunction

  /*
   * Make sure that we do not request more data than what fits into the
   * store-and-forward burst memory.
   */
  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      src_throttled_request_id <= 'h00;
    end else if (src_throttled_request_id != src_request_id &&
                 compare_id(src_throttled_request_id, src_data_request_id)) begin
      src_throttled_request_id <= inc_id(src_throttled_request_id);
    end
  end

  // --------------------------------------------------------------------------
  // Store-and-forward burst memory
  // --------------------------------------------------------------------------
  axi_dmac_burst_memory #(
    .DATA_WIDTH(DMA_DATA_WIDTH),
    .ID_WIDTH(ID_WIDTH),
    .MAX_BYTES_PER_BURST(MAX_BYTES_PER_BURST),
    .BYTES_PER_BEAT_WIDTH(BYTES_PER_BEAT_WIDTH),
    .BYTES_PER_BURST_WIDTH(BYTES_PER_BURST_WIDTH)
  ) i_store_and_forward (
    .clk(clk),
    .reset(~resetn),

    .src_data_valid(src_valid),
    .src_data(src_data),
    .src_data_last(src_last),
    .src_data_valid_bytes(src_valid_bytes),

    .src_data_request_id(src_data_request_id),

    .dest_data_valid(dest_valid),
    .dest_data_ready(dest_ready),
    .dest_data(dest_data),
    .dest_data_last(dest_last),
    .dest_data_strb(dest_strb),

    .dest_burst_info_length(dest_burst_info_length),
    .dest_burst_info_id(dest_burst_info_id),
    .dest_burst_info_write(dest_burst_info_write),

    .dest_request_id(dest_request_id),
    .dest_data_request_id(dest_data_request_id),
    .dest_data_response_id(dest_data_response_id));

  // --------------------------------------------------------------------------
  // Request distribution
  // --------------------------------------------------------------------------
  // Don't let the request generator run in advance more than one descriptor
  // The descriptor FIFO should not block the start of the request generator
  // since it becomes ready earlier.
  assign req_gen_valid = req_valid & req_ready;
  assign req_src_valid = req_valid & req_ready;
  assign req_ready = req_gen_ready & req_src_ready;

  util_axis_fifo #(
    .DATA_WIDTH(DMA_ADDRESS_WIDTH),
    .ADDRESS_WIDTH(0)
  ) i_dest_req_fifo (
    .clk(clk),
    .resetn(resetn),
    .s_axis_valid(src_dest_valid_hs),
    .s_axis_ready(src_dest_ready_hs),
    .s_axis_data(src_req_dest_address_cur),
    .m_axis_valid(dest_req_valid),
    .m_axis_ready(dest_req_ready),
    .m_axis_data(dest_req_dest_address));

  util_axis_fifo #(
    .DATA_WIDTH(DMA_ADDRESS_WIDTH + DMA_ADDRESS_WIDTH + BYTES_PER_BURST_WIDTH),
    .ADDRESS_WIDTH(0)
  ) i_src_req_fifo (
    .clk(clk),
    .resetn(resetn),
    .s_axis_valid(req_src_valid),
    .s_axis_ready(req_src_ready),
    .s_axis_data({
      req_dest_address,
      req_src_address,
      req_length[BYTES_PER_BURST_WIDTH-1:0]}),
    .m_axis_valid(src_req_spltr_valid),
    .m_axis_ready(src_req_spltr_ready),
    .m_axis_data({
      src_req_dest_address,
      src_req_src_address,
      src_req_last_burst_length,
      src_req_last_beat_bytes}));

  // Save the destination address on the source side since the submission to
  // the destination is delayed.
  always @(posedge clk) begin
    if (src_req_valid == 1'b1 && src_req_ready == 1'b1) begin
      src_req_dest_address_cur <= src_req_dest_address;
    end
  end

  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      src_dest_valid_hs <= 1'b0;
    end else if (src_req_valid == 1'b1 && src_req_ready == 1'b1) begin
      src_dest_valid_hs <= 1'b1;
    end else if (src_dest_ready_hs == 1'b1) begin
      src_dest_valid_hs <= 1'b0;
    end
  end

  assign src_req_spltr_ready = src_req_ready && src_dest_ready_hs;
  assign src_req_valid = src_req_spltr_valid && src_req_spltr_ready;

  request_generator #(
    .ID_WIDTH(ID_WIDTH),
    .BURSTS_PER_TRANSFER_WIDTH(BURSTS_PER_TRANSFER_WIDTH)
  ) i_req_gen (
    .clk(clk),
    .resetn(resetn),

    .request_id(request_id),
    .response_id(response_id),

    .req_valid(req_gen_valid),
    .req_ready(req_gen_ready),
    .req_burst_count(req_length[DMA_LENGTH_WIDTH-1:BYTES_PER_BURST_WIDTH]),

    .enable(req_enable),

    .eot(request_eot));

  axi_dmac_response_manager #(
    .BYTES_PER_BURST_WIDTH(BYTES_PER_BURST_WIDTH)
  ) i_response_manager (
    .clk(clk),
    .resetn(resetn),

    .dest_response_valid(dest_response_valid),
    .dest_response_ready(dest_response_ready),
    .dest_response_resp_eot(dest_response_resp_eot),
    .dest_response_data_burst_length(dest_response_data_burst_length),

    .response_eot(eot),
    .measured_burst_length(measured_burst_length),
    .response_valid(response_valid),
    .response_ready(response_ready));

endmodule
