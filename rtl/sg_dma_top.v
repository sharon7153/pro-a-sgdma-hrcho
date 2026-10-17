// ============================================================================
// sg_dma_top.v
//   Scatter-Gather DMA, memory -> memory, single clock domain.
//   Derived from ADI axi_dmac (hdl_2026_r1 / b62abeff), reduced to the SG
//   memcpy configuration only.
//
//   Fixed configuration:
//     - SG enabled (register mode still available via CONTROL.HWDESC = 0)
//     - Source and destination are AXI4 memory-mapped, same data width
//     - One clock (clk) and one reset (resetn) for every interface
//     - No 2D / cyclic / framelock / autorun / ext sync / AXI-Stream / FIFO
//
//   Exposed interfaces:
//     - s_axi_*      : AXI4-Lite slave  (register map, 11-bit address)
//     - m_src_axi_*  : AXI4 master, read-only  (source data)
//     - m_dest_axi_* : AXI4 master, write-only (destination data)
//     - m_sg_axi_*   : AXI4 master, read-only  (descriptor fetch, 64-bit fixed)
//     - irq
//
//   AXI ID / LOCK are brought out on every master port so the interface is a
//   complete AXI4 master and can sit behind an interconnect. IDs and LOCK are
//   driven to 0; RID / BID and RRESP / BRESP are not checked.
//
//   Module hierarchy:
//     sg_dma_top
//     +- axi_dmac_regmap            register map (AXI4-Lite, IRQ, control)
//     |  +- up_axi                  AXI4-Lite -> simple register bus
//     |  +- axi_dmac_regmap_request transfer request registers
//     +- axi_dmac_transfer
//        +- axi_dmac_reset_manager  ENABLE / PAUSE sequencing, internal reset
//        +- dmac_sg                 descriptor fetch
//        +- request_arb             data mover
//           +- request_generator         burst IDs
//           +- src_axi_mm                source read     (address_generator)
//           +- axi_dmac_burst_memory     store-and-forward buffer
//           +- dest_axi_mm               destination write (address_generator,
//           |                                               response_handler)
//           +- axi_dmac_response_manager completion reporting
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module sg_dma_top #(
  parameter ID                  = 0,        // PERIPHERAL_ID (0x004)
  parameter ADDR_WIDTH          = 32,       // master address width (> 32 enables *_HIGH registers)
  parameter DATA_WIDTH          = 64,       // source / destination data width
  parameter LENGTH_WIDTH        = 24,       // X_LENGTH / x_len width
  parameter MAX_BYTES_PER_BURST = 128,
  parameter FIFO_SIZE           = 8,        // in bursts
  parameter AXI_ID_WIDTH        = 1,
  parameter [3:0] AXI_AXCACHE   = 4'b0000,  // Device Non-bufferable - team decision 2026-10-06
  parameter [2:0] AXI_AXPROT    = 3'b000    // team decision 2026-10-06
) (
  input  wire                     clk,
  input  wire                     resetn,

  // --------------------------------------------------------------------------
  // AXI4-Lite slave : register map
  // --------------------------------------------------------------------------
  input  wire                     s_axi_awvalid,
  output wire                     s_axi_awready,
  input  wire [10:0]              s_axi_awaddr,
  input  wire [2:0]               s_axi_awprot,   // unused
  input  wire                     s_axi_wvalid,
  output wire                     s_axi_wready,
  input  wire [31:0]              s_axi_wdata,
  input  wire [3:0]               s_axi_wstrb,    // unused, writes are 32-bit
  output wire                     s_axi_bvalid,
  input  wire                     s_axi_bready,
  output wire [1:0]               s_axi_bresp,
  input  wire                     s_axi_arvalid,
  output wire                     s_axi_arready,
  input  wire [10:0]              s_axi_araddr,
  input  wire [2:0]               s_axi_arprot,   // unused
  output wire                     s_axi_rvalid,
  input  wire                     s_axi_rready,
  output wire [1:0]               s_axi_rresp,
  output wire [31:0]              s_axi_rdata,

  output wire                     irq,

  // --------------------------------------------------------------------------
  // AXI4 master (read-only) : source data
  // --------------------------------------------------------------------------
  output wire                     m_src_axi_arvalid,
  input  wire                     m_src_axi_arready,
  output wire [ADDR_WIDTH-1:0]    m_src_axi_araddr,
  output wire [7:0]               m_src_axi_arlen,
  output wire [2:0]               m_src_axi_arsize,
  output wire [1:0]               m_src_axi_arburst,
  output wire [2:0]               m_src_axi_arprot,
  output wire [3:0]               m_src_axi_arcache,
  output wire [AXI_ID_WIDTH-1:0]  m_src_axi_arid,
  output wire [0:0]               m_src_axi_arlock,
  input  wire                     m_src_axi_rvalid,
  output wire                     m_src_axi_rready,
  input  wire [DATA_WIDTH-1:0]    m_src_axi_rdata,
  input  wire [1:0]               m_src_axi_rresp,  // unused
  input  wire [AXI_ID_WIDTH-1:0]  m_src_axi_rid,    // unused
  input  wire                     m_src_axi_rlast,

  // --------------------------------------------------------------------------
  // AXI4 master (write-only) : destination data
  // --------------------------------------------------------------------------
  output wire                     m_dest_axi_awvalid,
  input  wire                     m_dest_axi_awready,
  output wire [ADDR_WIDTH-1:0]    m_dest_axi_awaddr,
  output wire [7:0]               m_dest_axi_awlen,
  output wire [2:0]               m_dest_axi_awsize,
  output wire [1:0]               m_dest_axi_awburst,
  output wire [2:0]               m_dest_axi_awprot,
  output wire [3:0]               m_dest_axi_awcache,
  output wire [AXI_ID_WIDTH-1:0]  m_dest_axi_awid,
  output wire [0:0]               m_dest_axi_awlock,
  output wire                     m_dest_axi_wvalid,
  input  wire                     m_dest_axi_wready,
  output wire [DATA_WIDTH-1:0]    m_dest_axi_wdata,
  output wire [DATA_WIDTH/8-1:0]  m_dest_axi_wstrb,
  output wire                     m_dest_axi_wlast,
  input  wire                     m_dest_axi_bvalid,
  output wire                     m_dest_axi_bready,
  input  wire [1:0]               m_dest_axi_bresp,  // unused
  input  wire [AXI_ID_WIDTH-1:0]  m_dest_axi_bid,    // unused

  // --------------------------------------------------------------------------
  // AXI4 master (read-only) : SG descriptor fetch (data width fixed to 64)
  // --------------------------------------------------------------------------
  output wire                     m_sg_axi_arvalid,
  input  wire                     m_sg_axi_arready,
  output wire [ADDR_WIDTH-1:0]    m_sg_axi_araddr,
  output wire [7:0]               m_sg_axi_arlen,
  output wire [2:0]               m_sg_axi_arsize,
  output wire [1:0]               m_sg_axi_arburst,
  output wire [2:0]               m_sg_axi_arprot,
  output wire [3:0]               m_sg_axi_arcache,
  output wire [AXI_ID_WIDTH-1:0]  m_sg_axi_arid,
  output wire [0:0]               m_sg_axi_arlock,
  input  wire                     m_sg_axi_rvalid,
  output wire                     m_sg_axi_rready,
  input  wire [63:0]              m_sg_axi_rdata,
  input  wire [1:0]               m_sg_axi_rresp,   // unused
  input  wire [AXI_ID_WIDTH-1:0]  m_sg_axi_rid,     // unused
  input  wire                     m_sg_axi_rlast
);

  // --------------------------------------------------------------------------
  // Derived parameters
  // --------------------------------------------------------------------------
  localparam BYTES_PER_BEAT_WIDTH = $clog2(DATA_WIDTH/8);

  // Burst IDs are gray counted and one bit wider than needed for FIFO_SIZE
  localparam ID_WIDTH = FIFO_SIZE > 1 ? $clog2(FIFO_SIZE*2) : 1;
  localparam DBG_ID_PADDING = ID_WIDTH > 8 ? 0 : 8 - ID_WIDTH;

  // AXI4 allows at most 256 beats per burst
  localparam BYTES_PER_BURST_LIMIT = 256 * DATA_WIDTH / 8;
  localparam REAL_MAX_BYTES_PER_BURST =
    BYTES_PER_BURST_LIMIT < MAX_BYTES_PER_BURST ?
      BYTES_PER_BURST_LIMIT : MAX_BYTES_PER_BURST;
  localparam BYTES_PER_BURST_WIDTH = $clog2(REAL_MAX_BYTES_PER_BURST);

  // --------------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------------
  wire ctrl_enable;
  wire ctrl_pause;
  wire ctrl_hwdesc;

  wire req_valid;
  wire req_ready;
  wire [ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] req_dest_address;
  wire [ADDR_WIDTH-1:BYTES_PER_BEAT_WIDTH] req_src_address;
  wire [ADDR_WIDTH-1:3] req_sg_address;
  wire [LENGTH_WIDTH-1:0] req_x_length;

  wire req_eot;
  wire [31:0] req_sg_desc_id;
  wire [BYTES_PER_BURST_WIDTH-1:0] req_measured_burst_length;
  wire req_response_valid;
  wire req_response_ready;

  wire [ID_WIDTH-1:0] dest_request_id;
  wire [ID_WIDTH-1:0] dest_data_id;
  wire [ID_WIDTH-1:0] dest_address_id;
  wire [ID_WIDTH-1:0] dest_response_id;
  wire [ID_WIDTH-1:0] src_request_id;
  wire [ID_WIDTH-1:0] src_data_id;
  wire [ID_WIDTH-1:0] src_address_id;
  wire [ID_WIDTH-1:0] src_response_id;
  wire [11:0] dbg_status;
  wire [31:0] dbg_ids0;
  wire [31:0] dbg_ids1;

  assign dbg_ids0 = {
    {DBG_ID_PADDING{1'b0}}, dest_response_id,
    {DBG_ID_PADDING{1'b0}}, dest_data_id,
    {DBG_ID_PADDING{1'b0}}, dest_address_id,
    {DBG_ID_PADDING{1'b0}}, dest_request_id
  };

  assign dbg_ids1 = {
    {DBG_ID_PADDING{1'b0}}, src_response_id,
    {DBG_ID_PADDING{1'b0}}, src_data_id,
    {DBG_ID_PADDING{1'b0}}, src_address_id,
    {DBG_ID_PADDING{1'b0}}, src_request_id
  };

  // --------------------------------------------------------------------------
  // Register map
  // --------------------------------------------------------------------------
  axi_dmac_regmap #(
    .ID                    (ID),
    .BYTES_PER_BEAT_WIDTH  (BYTES_PER_BEAT_WIDTH),
    .BYTES_PER_BURST_WIDTH (BYTES_PER_BURST_WIDTH),
    .DMA_AXI_ADDR_WIDTH    (ADDR_WIDTH),
    .DMA_LENGTH_WIDTH      (LENGTH_WIDTH),
    .AXI_AXCACHE           (AXI_AXCACHE),
    .AXI_AXPROT            (AXI_AXPROT)
  ) i_regmap (
    .s_axi_aclk     (clk),
    .s_axi_aresetn  (resetn),

    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awready  (s_axi_awready),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wready   (s_axi_wready),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bready   (s_axi_bready),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_araddr   (s_axi_araddr),
    .s_axi_arready  (s_axi_arready),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .s_axi_rresp    (s_axi_rresp),
    .s_axi_rdata    (s_axi_rdata),

    .irq            (irq),

    .ctrl_enable    (ctrl_enable),
    .ctrl_pause     (ctrl_pause),
    .ctrl_hwdesc    (ctrl_hwdesc),

    .request_valid        (req_valid),
    .request_ready        (req_ready),
    .request_dest_address (req_dest_address),
    .request_src_address  (req_src_address),
    .request_sg_address   (req_sg_address),
    .request_x_length     (req_x_length),

    .response_eot                   (req_eot),
    .response_sg_desc_id            (req_sg_desc_id),
    .response_measured_burst_length (req_measured_burst_length),
    .response_valid                 (req_response_valid),
    .response_ready                 (req_response_ready),

    .dbg_dest_addr  (m_dest_axi_awaddr),
    .dbg_src_addr   (m_src_axi_araddr),
    .dbg_status     (dbg_status),
    .dbg_ids0       (dbg_ids0),
    .dbg_ids1       (dbg_ids1));

  // --------------------------------------------------------------------------
  // Transfer path
  // --------------------------------------------------------------------------
  axi_dmac_transfer #(
    .DMA_DATA_WIDTH        (DATA_WIDTH),
    .DMA_LENGTH_WIDTH      (LENGTH_WIDTH),
    .BYTES_PER_BEAT_WIDTH  (BYTES_PER_BEAT_WIDTH),
    .DMA_AXI_ADDR_WIDTH    (ADDR_WIDTH),
    .MAX_BYTES_PER_BURST   (REAL_MAX_BYTES_PER_BURST),
    .BYTES_PER_BURST_WIDTH (BYTES_PER_BURST_WIDTH),
    .ID_WIDTH              (ID_WIDTH),
    .AXI_AXCACHE           (AXI_AXCACHE),
    .AXI_AXPROT            (AXI_AXPROT)
  ) i_transfer (
    .clk            (clk),
    .resetn         (resetn),

    .ctrl_enable    (ctrl_enable),
    .ctrl_pause     (ctrl_pause),
    .ctrl_hwdesc    (ctrl_hwdesc),

    .req_valid        (req_valid),
    .req_ready        (req_ready),
    .req_dest_address (req_dest_address),
    .req_src_address  (req_src_address),
    .req_sg_address   (req_sg_address),
    .req_x_length     (req_x_length),

    .req_eot                   (req_eot),
    .req_sg_desc_id            (req_sg_desc_id),
    .req_measured_burst_length (req_measured_burst_length),
    .req_response_valid        (req_response_valid),
    .req_response_ready        (req_response_ready),

    .m_axi_awaddr   (m_dest_axi_awaddr),
    .m_axi_awlen    (m_dest_axi_awlen),
    .m_axi_awsize   (m_dest_axi_awsize),
    .m_axi_awburst  (m_dest_axi_awburst),
    .m_axi_awprot   (m_dest_axi_awprot),
    .m_axi_awcache  (m_dest_axi_awcache),
    .m_axi_awvalid  (m_dest_axi_awvalid),
    .m_axi_awready  (m_dest_axi_awready),

    .m_axi_wdata    (m_dest_axi_wdata),
    .m_axi_wstrb    (m_dest_axi_wstrb),
    .m_axi_wready   (m_dest_axi_wready),
    .m_axi_wvalid   (m_dest_axi_wvalid),
    .m_axi_wlast    (m_dest_axi_wlast),

    .m_axi_bvalid   (m_dest_axi_bvalid),
    .m_axi_bready   (m_dest_axi_bready),

    .m_axi_arready  (m_src_axi_arready),
    .m_axi_arvalid  (m_src_axi_arvalid),
    .m_axi_araddr   (m_src_axi_araddr),
    .m_axi_arlen    (m_src_axi_arlen),
    .m_axi_arsize   (m_src_axi_arsize),
    .m_axi_arburst  (m_src_axi_arburst),
    .m_axi_arprot   (m_src_axi_arprot),
    .m_axi_arcache  (m_src_axi_arcache),

    .m_axi_rdata    (m_src_axi_rdata),
    .m_axi_rready   (m_src_axi_rready),
    .m_axi_rvalid   (m_src_axi_rvalid),
    .m_axi_rlast    (m_src_axi_rlast),

    .m_sg_axi_arready (m_sg_axi_arready),
    .m_sg_axi_arvalid (m_sg_axi_arvalid),
    .m_sg_axi_araddr  (m_sg_axi_araddr),
    .m_sg_axi_arlen   (m_sg_axi_arlen),
    .m_sg_axi_arsize  (m_sg_axi_arsize),
    .m_sg_axi_arburst (m_sg_axi_arburst),
    .m_sg_axi_arprot  (m_sg_axi_arprot),
    .m_sg_axi_arcache (m_sg_axi_arcache),

    .m_sg_axi_rdata   (m_sg_axi_rdata),
    .m_sg_axi_rready  (m_sg_axi_rready),
    .m_sg_axi_rvalid  (m_sg_axi_rvalid),
    .m_sg_axi_rlast   (m_sg_axi_rlast),

    .dbg_dest_request_id  (dest_request_id),
    .dbg_dest_address_id  (dest_address_id),
    .dbg_dest_data_id     (dest_data_id),
    .dbg_dest_response_id (dest_response_id),
    .dbg_src_request_id   (src_request_id),
    .dbg_src_address_id   (src_address_id),
    .dbg_src_data_id      (src_data_id),
    .dbg_src_response_id  (src_response_id),
    .dbg_status           (dbg_status));

  // AXI ID / LOCK : single ID, normal access
  assign m_src_axi_arid    = {AXI_ID_WIDTH{1'b0}};
  assign m_src_axi_arlock  = 1'b0;
  assign m_dest_axi_awid   = {AXI_ID_WIDTH{1'b0}};
  assign m_dest_axi_awlock = 1'b0;
  assign m_sg_axi_arid     = {AXI_ID_WIDTH{1'b0}};
  assign m_sg_axi_arlock   = 1'b0;

endmodule

`default_nettype wire
