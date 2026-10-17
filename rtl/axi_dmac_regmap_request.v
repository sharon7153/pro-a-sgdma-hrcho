// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2018-2025 Analog Devices, Inc. All rights reserved.
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

// Transfer request registers (0x404 - 0x4BC).
//
// Registers of features that are not built in this configuration keep their
// address and read as 0 (writes are ignored):
//   0x41C Y_LENGTH, 0x420 DEST_STRIDE, 0x424 SRC_STRIDE         (2D transfer)
//   0x44C PARTIAL_TRANSFER_LENGTH, 0x450 PARTIAL_TRANSFER_ID     (AXI-Stream source)
//   0x458 FRAMELOCK_CONFIG, 0x45C FRAMELOCK_STRIDE               (framelock)
//   FLAGS[0] CYCLIC                                              (cyclic mode)
module axi_dmac_regmap_request #(
  parameter BYTES_PER_BEAT_WIDTH = 3,
  parameter BYTES_PER_BURST_WIDTH = 7,
  parameter DMA_AXI_ADDR_WIDTH = 32,
  parameter DMA_LENGTH_WIDTH = 24
) (
  input clk,
  input reset,

  // Interrupts
  output up_sot,
  output up_eot,

  // Register map interface
  input up_wreq,
  input [8:0] up_waddr,
  input [31:0] up_wdata,
  input [8:0] up_raddr,
  output reg [31:0] up_rdata,

  // Control interface
  input ctrl_enable,

  // DMA request interface
  output request_valid,
  input request_ready,
  output [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] request_dest_address,
  output [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] request_src_address,
  output [DMA_AXI_ADDR_WIDTH-1:3] request_sg_address,
  output [DMA_LENGTH_WIDTH-1:0] request_x_length,

  // DMA response interface
  input response_eot,
  input [31:0] response_sg_desc_id,
  input [BYTES_PER_BURST_WIDTH-1:0] response_measured_burst_length,
  input response_valid,
  output reg response_ready = 1'b1
);

  localparam HAS_ADDR_HIGH = DMA_AXI_ADDR_WIDTH > 32;
  localparam ADDR_LOW_MSB = HAS_ADDR_HIGH ? 31 : DMA_AXI_ADDR_WIDTH-1;
  localparam ADDR_HIGH_MSB = HAS_ADDR_HIGH ? DMA_AXI_ADDR_WIDTH-32-1 : 0;

  // DMA transfer signals
  reg up_dma_req_valid = 1'b0;

  reg [1:0] up_transfer_id = 2'b0;
  reg [1:0] up_transfer_id_eot = 2'b0;
  reg [3:0] up_transfer_done_bitmap = 4'b0;

  reg [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] up_dma_dest_address = 'h00;
  reg [DMA_AXI_ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] up_dma_src_address = 'h00;
  reg [DMA_AXI_ADDR_WIDTH-1:3] up_dma_sg_address = 'h00;
  reg [DMA_LENGTH_WIDTH-1:0] up_dma_x_length = 'h00;
  // FLAGS[1] TLAST and FLAGS[2] PARTIAL_REPORTING_EN are kept as plain RW bits;
  // they have no effect on an MM -> MM transfer.
  reg up_dma_last = 1'b1;
  reg up_dma_enable_tlen_reporting = 1'b0;

  reg [DMA_LENGTH_WIDTH-1:0] up_measured_transfer_length = 'h0;
  reg up_clear_tl = 1'b0;

  assign request_dest_address = up_dma_dest_address;
  assign request_src_address = up_dma_src_address;
  assign request_sg_address = up_dma_sg_address;
  assign request_x_length = up_dma_x_length;

  always @(posedge clk) begin
    if (reset == 1'b1) begin
      up_dma_src_address <= 'h00;
      up_dma_dest_address <= 'h00;
      up_dma_sg_address <= 'h00;
      up_dma_x_length <= 'h00;
      up_dma_req_valid <= 1'b0;
      up_dma_last <= 1'b1;
      up_dma_enable_tlen_reporting <= 1'b0;
    end else begin
      // TRANSFER_SUBMIT: ignored while ENABLE = 0, self-clears when accepted
      if (ctrl_enable == 1'b1) begin
        if (up_wreq == 1'b1 && up_waddr == 9'h102) begin
          up_dma_req_valid <= up_dma_req_valid | up_wdata[0];
        end else if (up_sot == 1'b1) begin
          up_dma_req_valid <= 1'b0;
        end
      end else begin
        up_dma_req_valid <= 1'b0;
      end

      if (up_wreq == 1'b1) begin
        case (up_waddr)
        9'h103: begin
          up_dma_last <= up_wdata[1];
          up_dma_enable_tlen_reporting <= up_wdata[2];
        end
        9'h104: up_dma_dest_address[ADDR_LOW_MSB:BYTES_PER_BEAT_WIDTH] <= up_wdata[ADDR_LOW_MSB:BYTES_PER_BEAT_WIDTH];
        9'h105: up_dma_src_address[ADDR_LOW_MSB:BYTES_PER_BEAT_WIDTH] <= up_wdata[ADDR_LOW_MSB:BYTES_PER_BEAT_WIDTH];
        9'h106: up_dma_x_length <= up_wdata[DMA_LENGTH_WIDTH-1:0];
        9'h11f: up_dma_sg_address[ADDR_LOW_MSB:3] <= up_wdata[ADDR_LOW_MSB:3];
        9'h124:
          if (HAS_ADDR_HIGH) begin
            up_dma_dest_address[DMA_AXI_ADDR_WIDTH-1:HAS_ADDR_HIGH*32] <= up_wdata[ADDR_HIGH_MSB:0];
          end
        9'h125:
          if (HAS_ADDR_HIGH) begin
            up_dma_src_address[DMA_AXI_ADDR_WIDTH-1:HAS_ADDR_HIGH*32] <= up_wdata[ADDR_HIGH_MSB:0];
          end
        9'h12f:
          if (HAS_ADDR_HIGH) begin
            up_dma_sg_address[DMA_AXI_ADDR_WIDTH-1:HAS_ADDR_HIGH*32] <= up_wdata[ADDR_HIGH_MSB:0];
          end
        endcase
      end
    end
  end

  always @(*) begin
    case (up_raddr)
    9'h101: up_rdata <= up_transfer_id;
    9'h102: up_rdata <= up_dma_req_valid;
    9'h103: up_rdata <= {29'h00, up_dma_enable_tlen_reporting, up_dma_last, 1'b0}; // Flags
    9'h104: up_rdata <= {up_dma_dest_address[ADDR_LOW_MSB:BYTES_PER_BEAT_WIDTH],{BYTES_PER_BEAT_WIDTH{1'b0}}};
    9'h105: up_rdata <= {up_dma_src_address[ADDR_LOW_MSB:BYTES_PER_BEAT_WIDTH],{BYTES_PER_BEAT_WIDTH{1'b0}}};
    9'h106: up_rdata <= up_dma_x_length;
    9'h10a: up_rdata <= {28'b0,up_transfer_done_bitmap};
    9'h10b: up_rdata <= up_transfer_id_eot;
    9'h112: up_rdata <= up_measured_transfer_length;
    9'h115: up_rdata <= response_sg_desc_id;
    9'h11f: up_rdata <= {up_dma_sg_address[ADDR_LOW_MSB:3],3'b000};
    9'h124: up_rdata <= HAS_ADDR_HIGH ? up_dma_dest_address[DMA_AXI_ADDR_WIDTH-1:HAS_ADDR_HIGH*32] : 32'h00;
    9'h125: up_rdata <= HAS_ADDR_HIGH ? up_dma_src_address[DMA_AXI_ADDR_WIDTH-1:HAS_ADDR_HIGH*32] : 32'h00;
    9'h12f: up_rdata <= HAS_ADDR_HIGH ? up_dma_sg_address[DMA_AXI_ADDR_WIDTH-1:HAS_ADDR_HIGH*32] : 32'h00;
    default: up_rdata <= 32'h00;
    endcase
  end

  assign up_sot = up_dma_req_valid & request_ready;
  assign up_eot = response_eot & response_valid & response_ready;

  assign request_valid = up_dma_req_valid;

  // Request ID and Request done bitmap handling
  always @(posedge clk) begin
    if (ctrl_enable == 1'b0) begin
      up_transfer_id <= 2'h0;
      up_transfer_id_eot <= 2'h0;
      up_transfer_done_bitmap <= 4'h0;
    end else begin
      if (up_sot == 1'b1) begin
        up_transfer_id <= up_transfer_id + 1'b1;
        up_transfer_done_bitmap[up_transfer_id] <= 1'b0;
      end

      if (up_eot == 1'b1) begin
        up_transfer_id_eot <= up_transfer_id_eot + 1'b1;
        up_transfer_done_bitmap[up_transfer_id_eot] <= 1'b1;
      end
    end
  end

  // TRANSFER_PROGRESS: bytes completed in the current transfer, cleared after EOT
  always @(posedge clk) begin
    if (ctrl_enable == 1'b0) begin
      up_measured_transfer_length <= 'h0;
    end else if (response_valid == 1'b1 && response_ready == 1'b1) begin
      up_measured_transfer_length <= up_measured_transfer_length + response_measured_burst_length + 1'b1;
    end else if (up_clear_tl == 1'b1) begin
      up_measured_transfer_length <= 'h0;
    end
  end

  always @(posedge clk) begin
    if (ctrl_enable == 1'b0) begin
      response_ready <= 1'b1;
    end else if (response_ready == 1'b1) begin
      response_ready <= ~response_valid;
    end else begin
      response_ready <= 1'b1;
    end
  end

  always @(posedge clk)
  begin
    if (response_valid == 1'b1 && response_ready == 1'b1) begin
      up_clear_tl <= response_eot;
    end
  end

endmodule
