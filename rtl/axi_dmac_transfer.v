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

// Transfer path: reset manager, SG engine and the AXI-MM data mover.
// CONTROL.HWDESC selects where a transfer request comes from:
//   0 : register mode  (DEST_ADDRESS / SRC_ADDRESS / X_LENGTH)
//   1 : SG mode        (descriptor chain starting at SG_ADDRESS)
module axi_dmac_transfer #(
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

  input ctrl_enable,
  input ctrl_pause,
  input ctrl_hwdesc,

  input req_valid,
  output req_ready,

  input [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] req_dest_address,
  input [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] req_src_address,
  input [DMA_AXI_ADDR_WIDTH-1:3] req_sg_address,
  input [DMA_LENGTH_WIDTH-1:0] req_x_length,

  output req_eot,
  output [31:0] req_sg_desc_id,
  output [BYTES_PER_BURST_WIDTH-1:0] req_measured_burst_length,
  output req_response_valid,
  input req_response_ready,

  // Destination write
  output [DMA_AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
  output [7:0] m_axi_awlen,
  output [2:0] m_axi_awsize,
  output [1:0] m_axi_awburst,
  output [2:0] m_axi_awprot,
  output [3:0] m_axi_awcache,
  output m_axi_awvalid,
  input m_axi_awready,

  output [DMA_DATA_WIDTH-1:0] m_axi_wdata,
  output [(DMA_DATA_WIDTH/8)-1:0] m_axi_wstrb,
  input m_axi_wready,
  output m_axi_wvalid,
  output m_axi_wlast,

  input m_axi_bvalid,
  output m_axi_bready,

  // Source read
  input m_axi_arready,
  output m_axi_arvalid,
  output [DMA_AXI_ADDR_WIDTH-1:0] m_axi_araddr,
  output [7:0] m_axi_arlen,
  output [2:0] m_axi_arsize,
  output [1:0] m_axi_arburst,
  output [2:0] m_axi_arprot,
  output [3:0] m_axi_arcache,

  input [DMA_DATA_WIDTH-1:0] m_axi_rdata,
  input m_axi_rlast,
  output m_axi_rready,
  input m_axi_rvalid,

  // Descriptor read
  input m_sg_axi_arready,
  output m_sg_axi_arvalid,
  output [DMA_AXI_ADDR_WIDTH-1:0] m_sg_axi_araddr,
  output [7:0] m_sg_axi_arlen,
  output [2:0] m_sg_axi_arsize,
  output [1:0] m_sg_axi_arburst,
  output [2:0] m_sg_axi_arprot,
  output [3:0] m_sg_axi_arcache,

  input [63:0] m_sg_axi_rdata,
  input m_sg_axi_rlast,
  output m_sg_axi_rready,
  input m_sg_axi_rvalid,

  output [ID_WIDTH-1:0] dbg_dest_request_id,
  output [ID_WIDTH-1:0] dbg_dest_address_id,
  output [ID_WIDTH-1:0] dbg_dest_data_id,
  output [ID_WIDTH-1:0] dbg_dest_response_id,
  output [ID_WIDTH-1:0] dbg_src_request_id,
  output [ID_WIDTH-1:0] dbg_src_address_id,
  output [ID_WIDTH-1:0] dbg_src_data_id,
  output [ID_WIDTH-1:0] dbg_src_response_id,
  output [11:0] dbg_status
);

  wire dma_resetn;

  wire dma_req_valid;
  wire dma_req_ready;
  wire [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] dma_req_dest_address;
  wire [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] dma_req_src_address;
  wire [DMA_LENGTH_WIDTH-1:0] dma_req_length;
  wire dma_eot;

  wire [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] dma_sg_out_dest_address;
  wire [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] dma_sg_out_src_address;
  wire [DMA_LENGTH_WIDTH-1:0] dma_sg_x_length;
  wire [31:0] dma_sg_hwdesc_id;
  wire dma_sg_hwdesc_eot;
  wire dma_sg_in_req_valid;
  wire dma_sg_in_req_ready;
  wire dma_sg_out_req_valid;
  wire dma_sg_out_req_ready;

  wire req_enable;
  wire dest_enable;
  wire dest_enabled;
  wire src_enable;
  wire src_enabled;
  wire sg_enable;
  wire sg_enabled;

  wire req_valid_gated;
  wire req_ready_gated;

  axi_dmac_reset_manager i_reset_manager (
    .clk (clk),
    .resetn (resetn),

    .ctrl_enable (ctrl_enable),
    .ctrl_pause (ctrl_pause),
    .ctrl_hwdesc (ctrl_hwdesc),

    .dma_resetn (dma_resetn),

    .req_enable (req_enable),
    .req_enabled (req_enable),

    .dest_enable (dest_enable),
    .dest_enabled (dest_enabled),

    .src_enable (src_enable),
    .src_enabled (src_enabled),

    .sg_enable (sg_enable),
    .sg_enabled (sg_enabled),

    .dbg_status (dbg_status));

  /*
   * Things become a lot easier if we gate incoming requests in a central place
   * before they are propagated downstream. Otherwise we'd need to take special
   * care to not accidentally accept requests while the DMA is going through a
   * shutdown and reset phase.
   */
  assign req_valid_gated = req_enable & req_valid;
  assign req_ready = req_enable & req_ready_gated;

  // In SG mode a completion is only reported for descriptors with EOT_IRQ set
  assign req_eot = ctrl_hwdesc ? (dma_eot & dma_sg_hwdesc_eot) : dma_eot;
  assign req_sg_desc_id = ctrl_hwdesc ? dma_sg_hwdesc_id : 'h00;
  assign dma_sg_in_req_valid = ctrl_hwdesc ? req_valid_gated : 1'b0;

  dmac_sg #(
    .DMA_AXI_ADDR_WIDTH(DMA_AXI_ADDR_WIDTH),
    .DMA_LENGTH_WIDTH(DMA_LENGTH_WIDTH),
    .BYTES_PER_BEAT_WIDTH(BYTES_PER_BEAT_WIDTH),
    .AXI_AXCACHE(AXI_AXCACHE),
    .AXI_AXPROT(AXI_AXPROT)
  ) i_dmac_sg (
    .clk(clk),
    .resetn(dma_resetn),

    .sg_enable(sg_enable),
    .sg_enabled(sg_enabled),

    .req_in_valid(dma_sg_in_req_valid),
    .req_in_ready(dma_sg_in_req_ready),

    .req_out_valid(dma_sg_out_req_valid),
    .req_out_ready(dma_sg_out_req_ready),

    .req_desc_address(req_sg_address),

    .out_dest_address(dma_sg_out_dest_address),
    .out_src_address(dma_sg_out_src_address),
    .out_x_length(dma_sg_x_length),
    .resp_out_id(dma_sg_hwdesc_id),
    .resp_out_eot(dma_sg_hwdesc_eot),
    .resp_in_valid(dma_eot),

    .m_axi_arready(m_sg_axi_arready),
    .m_axi_arvalid(m_sg_axi_arvalid),
    .m_axi_araddr(m_sg_axi_araddr),
    .m_axi_arlen(m_sg_axi_arlen),
    .m_axi_arsize(m_sg_axi_arsize),
    .m_axi_arburst(m_sg_axi_arburst),
    .m_axi_arprot(m_sg_axi_arprot),
    .m_axi_arcache(m_sg_axi_arcache),

    .m_axi_rdata(m_sg_axi_rdata),
    .m_axi_rlast(m_sg_axi_rlast),
    .m_axi_rready(m_sg_axi_rready),
    .m_axi_rvalid(m_sg_axi_rvalid));

  // Request source: SG engine or register map
  assign dma_req_valid = ctrl_hwdesc ? dma_sg_out_req_valid : req_valid_gated;
  assign req_ready_gated = ctrl_hwdesc ? dma_sg_in_req_ready : dma_req_ready;
  assign dma_sg_out_req_ready = dma_req_ready;

  assign dma_req_dest_address = ctrl_hwdesc ? dma_sg_out_dest_address : req_dest_address;
  assign dma_req_src_address = ctrl_hwdesc ? dma_sg_out_src_address : req_src_address;
  assign dma_req_length = ctrl_hwdesc ? dma_sg_x_length : req_x_length;

  request_arb #(
    .DMA_DATA_WIDTH (DMA_DATA_WIDTH),
    .DMA_LENGTH_WIDTH (DMA_LENGTH_WIDTH),
    .BYTES_PER_BEAT_WIDTH (BYTES_PER_BEAT_WIDTH),
    .DMA_AXI_ADDR_WIDTH (DMA_AXI_ADDR_WIDTH),
    .MAX_BYTES_PER_BURST (MAX_BYTES_PER_BURST),
    .BYTES_PER_BURST_WIDTH (BYTES_PER_BURST_WIDTH),
    .ID_WIDTH (ID_WIDTH),
    .AXI_AXCACHE (AXI_AXCACHE),
    .AXI_AXPROT (AXI_AXPROT)
  ) i_request_arb (
    .clk (clk),
    .resetn (dma_resetn),

    .req_valid (dma_req_valid),
    .req_ready (dma_req_ready),
    .req_dest_address (dma_req_dest_address),
    .req_src_address (dma_req_src_address),
    .req_length (dma_req_length),

    .eot (dma_eot),
    .measured_burst_length (req_measured_burst_length),
    .response_valid (req_response_valid),
    .response_ready (req_response_ready),

    .req_enable (req_enable),

    .dest_enable (dest_enable),
    .dest_enabled (dest_enabled),
    .src_enable (src_enable),
    .src_enabled (src_enabled),

    .m_axi_awvalid (m_axi_awvalid),
    .m_axi_awready (m_axi_awready),
    .m_axi_awaddr (m_axi_awaddr),
    .m_axi_awlen (m_axi_awlen),
    .m_axi_awsize (m_axi_awsize),
    .m_axi_awburst (m_axi_awburst),
    .m_axi_awprot (m_axi_awprot),
    .m_axi_awcache (m_axi_awcache),

    .m_axi_wvalid (m_axi_wvalid),
    .m_axi_wready (m_axi_wready),
    .m_axi_wdata (m_axi_wdata),
    .m_axi_wstrb (m_axi_wstrb),
    .m_axi_wlast (m_axi_wlast),

    .m_axi_bvalid (m_axi_bvalid),
    .m_axi_bready (m_axi_bready),

    .m_axi_arvalid (m_axi_arvalid),
    .m_axi_arready (m_axi_arready),
    .m_axi_araddr (m_axi_araddr),
    .m_axi_arlen (m_axi_arlen),
    .m_axi_arsize (m_axi_arsize),
    .m_axi_arburst (m_axi_arburst),
    .m_axi_arprot (m_axi_arprot),
    .m_axi_arcache (m_axi_arcache),

    .m_axi_rready (m_axi_rready),
    .m_axi_rvalid (m_axi_rvalid),
    .m_axi_rdata (m_axi_rdata),
    .m_axi_rlast (m_axi_rlast),

    .dbg_dest_request_id (dbg_dest_request_id),
    .dbg_dest_address_id (dbg_dest_address_id),
    .dbg_dest_data_id (dbg_dest_data_id),
    .dbg_dest_response_id (dbg_dest_response_id),
    .dbg_src_request_id (dbg_src_request_id),
    .dbg_src_address_id (dbg_src_address_id),
    .dbg_src_data_id (dbg_src_data_id),
    .dbg_src_response_id (dbg_src_response_id));

endmodule
