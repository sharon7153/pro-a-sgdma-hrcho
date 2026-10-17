// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2024 Analog Devices, Inc. All rights reserved.
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

// Forwards destination write responses to the register map, one per burst.
module axi_dmac_response_manager #(
  parameter BYTES_PER_BURST_WIDTH = 7
) (
  input clk,
  input resetn,

  // Interface to destination side
  input dest_response_valid,
  output dest_response_ready,
  input dest_response_resp_eot,
  input [BYTES_PER_BURST_WIDTH-1:0] dest_response_data_burst_length,

  // Interface to processor
  output response_eot,
  output reg [BYTES_PER_BURST_WIDTH-1:0] measured_burst_length = 'h0,
  output reg response_valid = 1'b0,
  input response_ready
);

  localparam STATE_IDLE         = 2'h0;
  localparam STATE_ACC          = 2'h1;
  localparam STATE_WRITE_RESPR  = 2'h2;

  reg [1:0] state = STATE_IDLE;
  reg [1:0] nx_state;

  reg req_eot = 1'b0;
  reg [BYTES_PER_BURST_WIDTH-1:0] req_response_dest_data_burst_length = 'h0;

  wire response_dest_valid;
  reg response_dest_ready = 1'b1;
  wire response_dest_resp_eot;
  wire [BYTES_PER_BURST_WIDTH-1:0] response_dest_data_burst_length;

  util_axis_fifo #(
    .DATA_WIDTH(BYTES_PER_BURST_WIDTH+1),
    .ADDRESS_WIDTH(0)
  ) i_dest_response_fifo (
    .clk(clk),
    .resetn(resetn),
    .s_axis_valid(dest_response_valid),
    .s_axis_ready(dest_response_ready),
    .s_axis_data({dest_response_data_burst_length,
                  dest_response_resp_eot}),
    .m_axis_valid(response_dest_valid),
    .m_axis_ready(response_dest_ready),
    .m_axis_data({response_dest_data_burst_length,
                  response_dest_resp_eot}));

  always @(posedge clk)
  begin
    if (resetn == 1'b0) begin
      req_eot <= 1'b0;
      req_response_dest_data_burst_length <= 'h0;
    end else if (response_dest_valid & response_dest_ready) begin
      req_eot <= response_dest_resp_eot;
      req_response_dest_data_burst_length <= response_dest_data_burst_length;
    end
  end

  always @(posedge clk)
  begin
    if (resetn == 1'b0) begin
      response_dest_ready <= 1'b1;
    end else begin
      response_dest_ready <= (nx_state == STATE_IDLE);
    end
  end

  assign response_eot = (state == STATE_WRITE_RESPR) ? req_eot : 1'b0;

  always @(posedge clk)
  begin
    if (resetn == 1'b0) begin
      response_valid <= 1'b0;
    end else begin
      if (nx_state == STATE_WRITE_RESPR) begin
        response_valid <= 1'b1;
      end else if (response_ready == 1'b1) begin
        response_valid <= 1'b0;
      end
    end
  end

  always @(posedge clk)
  begin
    if (state == STATE_ACC) begin
      measured_burst_length <= req_response_dest_data_burst_length;
    end
  end

  always @(*) begin
    nx_state = state;
    case (state)
      STATE_IDLE: begin
        if (response_dest_valid == 1'b1) begin
          nx_state = STATE_ACC;
        end
      end
      STATE_ACC: begin
        nx_state = STATE_WRITE_RESPR;
      end
      STATE_WRITE_RESPR: begin
        if (response_ready == 1'b1) begin
          nx_state = STATE_IDLE;
        end
      end
      default: begin
        nx_state = STATE_IDLE;
      end
    endcase
  end

  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      state <= STATE_IDLE;
    end else begin
      state <= nx_state;
    end
  end

endmodule
