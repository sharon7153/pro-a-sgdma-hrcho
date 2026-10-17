// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2023 Analog Devices, Inc. All rights reserved.
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

// ENABLE / PAUSE sequencing and the internal DMA reset (single clock domain).
module axi_dmac_reset_manager (
  input clk,
  input resetn,

  input ctrl_enable,
  input ctrl_pause,
  input ctrl_hwdesc,

  // Reset for every DMA-internal block (request, source, destination, SG)
  output dma_resetn,

  output req_enable,
  input req_enabled,

  output dest_enable,
  input dest_enabled,

  output src_enable,
  input src_enabled,

  output sg_enable,
  input sg_enabled,

  output [11:0] dbg_status
);

  localparam STATE_DO_RESET = 3'h0;
  localparam STATE_RESET = 3'h1;
  localparam STATE_DISABLED = 3'h2;
  localparam STATE_STARTUP = 3'h3;
  localparam STATE_ENABLED = 3'h4;
  localparam STATE_SHUTDOWN = 3'h5;

  reg [2:0] state = 3'b000;
  reg needs_reset = 1'b0;
  reg do_reset = 1'b0;
  reg do_enable = 1'b0;

  wire enabled_all;
  wire disabled_all;

  // The SG engine only takes part when hardware descriptors are in use
  assign enabled_all = req_enabled & src_enabled & dest_enabled & (sg_enabled | ~ctrl_hwdesc);
  assign disabled_all = ~(req_enabled | src_enabled | dest_enabled | (sg_enabled & ctrl_hwdesc));

  assign req_enable = do_enable;
  assign dest_enable = do_enable;
  assign src_enable = do_enable;
  assign sg_enable = do_enable;

  // DBG_STATUS (0x43C): {needs_reset, req/src/dest/sg resetn, req/src/dest/sg enabled, state}
  assign dbg_status = {needs_reset,
                       dma_resetn, dma_resetn, dma_resetn, dma_resetn,
                       req_enabled, src_enabled, dest_enabled, sg_enabled,
                       state};

  always @(posedge clk) begin
    if (state == STATE_DO_RESET) begin
      do_reset <= 1'b1;
    end else begin
      do_reset <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (state == STATE_STARTUP || state == STATE_ENABLED) begin
      do_enable <= 1'b1;
    end else begin
      do_enable <= 1'b0;
    end
  end

  /*
   * If ctrl_enable goes from 1 to 0 a shutdown procedure is initiated. During the
   * shutdown procedure all domains are signaled that a shutdown should occur. The
   * domains will then complete any active transactions that are required to
   * complete according to the interface semantics. Once a domain has completed
   * its transactions it will indicate that it has been shutdown. Once all domains
   * indicate that they have been disabled a reset pulse will be generated to all
   * domains to clear all residual state.
   *
   * Once the reset signal is de-asserted the DMA is in an idle state and can be
   * enabled again. If the DMA receives a enable while it is performing a shutdown
   * sequence it will only be re-enabled once the shutdown sequence has
   * successfully completed.
   *
   * If ctrl_pause is asserted all domains will be disabled. But there will be no
   * reset, so when the ctrl_pause signal is de-asserted again the DMA will resume
   * with its previous state.
   */

  /*
   * If ctrl_enable goes low, even for a single clock cycle, we want to go through
   * a full reset sequence. This might happen when the state machine is busy, e.g.
   * going through a startup sequence. To avoid missing the event store it for
   * later.
   */
  always @(posedge clk) begin
    if (state == STATE_RESET) begin
      needs_reset <= 1'b0;
    end else if (ctrl_enable == 1'b0) begin
      needs_reset <= 1'b1;
    end
  end

  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      state <= STATE_DO_RESET;
    end else begin
      case (state)
      STATE_DO_RESET: begin
        state <= STATE_RESET;
      end
      STATE_RESET: begin
        /*
         * Wait for the reset sequence to complete. Stay in this state when
         * ctrl_enable == 1'b0, otherwise we'd go through the reset sequence
         * again and again.
         */
        if (ctrl_enable == 1'b1 && dma_resetn == 1'b1) begin
          state <= STATE_DISABLED;
        end
      end
      STATE_DISABLED: begin
        if (needs_reset == 1'b1) begin
          state <= STATE_DO_RESET;
        end else if (ctrl_pause == 1'b0) begin
          state <= STATE_STARTUP;
        end
      end
      STATE_STARTUP: begin
        /* Wait for all domains to be ready */
        if (enabled_all == 1'b1) begin
          state <= STATE_ENABLED;
        end
      end
      STATE_ENABLED: begin
        if (needs_reset == 1'b1 || ctrl_pause == 1'b1) begin
          state <= STATE_SHUTDOWN;
        end
      end
      STATE_SHUTDOWN: begin
        /* Wait for all domains to complete outstanding transactions */
        if (disabled_all == 1'b1) begin
          state <= STATE_DISABLED;
        end
      end
      endcase
    end
  end

  /*
   * Reset pulse generator: do_reset asynchronously loads a 4-stage shift
   * register; once it drains, the reset is released through a 2-stage
   * synchronizer. The internal reset is therefore asserted for several cycles.
   */
  reg [3:0] reset_async = 4'b1111;
  reg [1:0] reset_sync = 2'b11;
  reg reset_sync_in = 1'b1;

  always @(posedge clk or posedge reset_async[0]) begin
    if (reset_async[0] == 1'b1) begin
      reset_sync_in <= 1'b1;
    end else begin
      reset_sync_in <= reset_async[0];
    end
  end

  always @(posedge clk or posedge do_reset) begin
    if (do_reset == 1'b1) begin
      reset_async <= 4'b1111;
    end else begin
      reset_async <= {1'b0, reset_async[3:1]};
    end
  end

  always @(posedge clk) begin
    reset_sync <= {reset_sync_in, reset_sync[1]};
  end

  assign dma_resetn = ~reset_sync[0];

endmodule
