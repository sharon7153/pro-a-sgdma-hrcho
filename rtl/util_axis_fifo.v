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

// Single-clock FIFO.
//   ADDRESS_WIDTH == 0 : one-stage pipeline register (valid/ready skid-free)
//   ADDRESS_WIDTH  > 0 : 2**ADDRESS_WIDTH - 1 entries, registered output
module util_axis_fifo #(
  parameter DATA_WIDTH = 64,
  parameter ADDRESS_WIDTH = 5
) (
  input clk,
  input resetn,

  input s_axis_valid,
  output s_axis_ready,
  input [DATA_WIDTH-1:0] s_axis_data,

  output m_axis_valid,
  input m_axis_ready,
  output [DATA_WIDTH-1:0] m_axis_data
);

  generate if (ADDRESS_WIDTH == 0) begin : zerodeep

    reg [DATA_WIDTH-1:0] axis_data_d;
    reg                  axis_valid_d;

    always @(posedge clk) begin
      if (!resetn) begin
        axis_data_d <= {DATA_WIDTH{1'b0}};
        axis_valid_d <= 1'b0;
      end else if (s_axis_ready) begin
        axis_data_d <= s_axis_data;
        axis_valid_d <= s_axis_valid;
      end
    end

    assign m_axis_data = axis_data_d;
    assign m_axis_valid = axis_valid_d;
    assign s_axis_ready = m_axis_ready | ~m_axis_valid;

  end else begin : fifo

    // Pointers are one bit wider than the address to detect wrap-around
    reg [ADDRESS_WIDTH:0] waddr = 'h0;
    reg [ADDRESS_WIDTH:0] raddr = 'h0;
    reg [DATA_WIDTH-1:0] ram[0:2**ADDRESS_WIDTH-1];
    reg [DATA_WIDTH-1:0] data;
    reg valid = 1'b0;

    wire [ADDRESS_WIDTH:0] fill = waddr - raddr;
    wire full = fill == {ADDRESS_WIDTH{1'b1}};
    wire not_empty = fill != 0;
    wire mem_write = s_axis_valid & ~full;
    wire mem_read = (~valid | m_axis_ready) & not_empty;

    assign s_axis_ready = ~full;
    assign m_axis_valid = valid;
    assign m_axis_data = data;

    always @(posedge clk) begin
      if (!resetn) begin
        waddr <= 'h0;
      end else if (mem_write) begin
        waddr <= waddr + 1'b1;
      end
    end

    always @(posedge clk) begin
      if (!resetn) begin
        raddr <= 'h0;
      end else if (mem_read) begin
        raddr <= raddr + 1'b1;
      end
    end

    always @(posedge clk) begin
      if (mem_write)
        ram[waddr[ADDRESS_WIDTH-1:0]] <= s_axis_data;
    end

    always @(posedge clk) begin
      if (mem_read)
        data <= ram[raddr[ADDRESS_WIDTH-1:0]];
    end

    // Output register valid: set while the FIFO holds data, cleared on accept
    always @(posedge clk) begin
      if (!resetn) begin
        valid <= 1'b0;
      end else if (not_empty) begin
        valid <= 1'b1;
      end else if (m_axis_ready) begin
        valid <= 1'b0;
      end
    end

  end
  endgenerate

endmodule
