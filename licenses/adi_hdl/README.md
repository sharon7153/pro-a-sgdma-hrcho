# ADI HDL sources

The RTL in `rtl/` is derived from the ADI HDL `axi_dmac` library and is covered
by the licenses in this folder. Each derived file keeps its original ADI
copyright and license header.

| item | value |
|---|---|
| upstream | https://github.com/analogdevicesinc/hdl |
| branch | `hdl_2026_r1` |
| commit | `b62abeff22d613d08e1aeb7f94850ab6a6576a74` |
| imported | 2026-10-04 |

## Local modifications

**2026-10-17 — reduced to the sg_dma configuration.** The code was cut down
to SG, AXI-MM to AXI-MM, a single clock, AXI4, and one data width. The following
were removed: AXI-Stream and FIFO interfaces, 2D transfer, framelock, cyclic
mode, autorun, external sync, async clock crossings, asymmetric data widths,
register slices, partial-transfer reporting, and the diagnostics interface.

- `axi_dmac.v` was merged into `sg_dma_top.v`.
- These modules were removed: `axi_dmac_ext_sync`, `axi_dmac_resize_src`,
  `axi_dmac_resize_dest`, `axi_register_slice`, `ad_mem_asym`, `sync_bits`,
  `util_axis_fifo_address_generator`, and `resp.vh`.
- `splitter.v`, `up_axi.v`, and `inc_id.vh` are unmodified.

Register addresses, bit fields, and reset values are unchanged. Registers of
the removed features read as 0. The reduced RTL was checked against the
pre-reduction RTL in a cycle-by-cycle lockstep simulation (all output ports
compared).

**2026-10-04 — burst memory 0-replication fix** (still present in
`rtl/axi_dmac_burst_memory.v`, now simplified to a reset value of 0):

```diff
- reg [BYTES_PER_BURST_WIDTH+1-1:0] dest_burst_len_data = {DMA_LENGTH_ALIGN{1'b1}};
+ reg [BYTES_PER_BURST_WIDTH+1-1:0] dest_burst_len_data = (1 << DMA_LENGTH_ALIGN) - 1;
```
