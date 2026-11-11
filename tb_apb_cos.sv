`timescale 1ns/1ps
module tb_apb_cos;

    // Шина APB
    logic        pclk = 1'b0;
    logic        presetn;
    logic        psel, penable, pwrite;
    logic [31:0] paddr, pwdata;
    wire  [31:0] prdata;
    wire         pready, pslverr;

    localparam logic [31:0] BASE     = 32'h7000_0000;
    localparam logic [3:0]  OFF_CTRL = 4'h0;
    localparam logic [3:0]  OFF_OUT  = 4'h4;
    localparam real         PI       = 3.14159265358979323846;

    apb_cos_slave DUT (
        .pclk(pclk), .presetn(presetn),
        .paddr(paddr), .pwdata(pwdata),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .pready(pready), .pslverr(pslverr), .prdata(prdata)
    );

    apb_master MASTER (
        .pclk(pclk), .presetn(presetn),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata),
        .pready(pready), .pslverr(pslverr), .prdata(prdata)
    );

    // Тактовый сигнал, период 20 нс
    initial forever #10 pclk = ~pclk;

    // Возвращает {знак, 8 BCD-тетрад модуля cos(k*pi/4) с 4 знаками после запятой}
    function automatic logic [15:0] to_bcd4(input int unsigned v);
        return {4'(v / 1000 % 10), 4'(v / 100 % 10), 4'(v / 10 % 10), 4'(v % 10)};
    endfunction

    function automatic logic [32:0] ref_cos(input int k);
        real         c;
        int unsigned scaled;
        logic        neg;
        c      = $cos(k * PI / 4.0);
        neg    = (c < -0.00005);               // порог защищает от «-0» при pi/2, 3pi/2
        scaled = $rtoi(((c < 0.0) ? -c : c) * 10000.0 + 0.5);
        return {neg, to_bcd4(scaled / 10000), to_bcd4(scaled % 10000)};
    endfunction

    // Слово CTRL, как его должен вернуть DUT
    function automatic logic [31:0] ctrl_word(input logic valid, sign,
                                              input logic [2:0] ang);
        return {22'd0, valid, sign, 5'd0, ang};
    endfunction

    // Монитор pslverr
    int err_hits = 0;
    always @(negedge pclk)
        if (psel && penable && pslverr) err_hits++;

    // Обёртки над задачами мастера 
    task automatic wr(input logic [3:0] off, input logic [31:0] d, output bit err);
        err_hits = 0;
        MASTER.apb_write(BASE + off, d);
        err = (err_hits != 0);
    endtask

    task automatic rd(input logic [3:0] off, output logic [31:0] d, output bit err);
        err_hits = 0;
        MASTER.apb_read(BASE + off, d);
        err = (err_hits != 0);
    endtask

    // Проверки 
    int n_checks = 0, n_fail = 0;
    task automatic expect_eq(input logic [31:0] got, exp, input string what);
        n_checks++;
        if (got !== exp) begin
            n_fail++;
            $error("[FAIL] %s: got 0x%h, expected 0x%h", what, got, exp);
        end
    endtask

    task automatic do_reset(input int cycles);
        presetn = 1'b0;
        repeat (cycles) @(posedge pclk);
        presetn = 1'b1;
        repeat (3) @(posedge pclk);
    endtask

    // Модель регистров для случайного теста
    logic [2:0]  m_ang;
    logic        m_sign, m_valid;
    logic [31:0] m_out;

    task automatic model_reset();
        m_ang = 0; m_sign = 0; m_valid = 0; m_out = 0;
    endtask

    task automatic model_ctrl_write(input logic [31:0] d);
        logic [32:0] r;
        if (d[4]) begin
            r = ref_cos(d[2:0]);
            {m_sign, m_out} = r;
            m_valid = 1'b1;
        end else if (d[2:0] != m_ang)
            m_valid = 1'b0;
        m_ang = d[2:0];
    endtask

    // Сценарии
    logic [31:0] rdata;
    bit          e;

    initial begin
        presetn = 1'b1;
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        repeat (3) @(posedge pclk);
        do_reset(4);
        model_reset();

        // 1. Значения после сброса
        $display("\n== A: reset values ==");
        rd(OFF_CTRL, rdata, e); expect_eq(rdata, 32'h0, "CTRL after reset");
        rd(OFF_OUT,  rdata, e); expect_eq(rdata, 32'h0, "OUT after reset");

        // 2. Двухшаговый запуск, углы в обратном порядке
        $display("\n== B: two-step start, k = 7..0 ==");
        for (int k = 7; k >= 0; k--) begin
            logic [32:0] r;
            r = ref_cos(k);
            wr(OFF_CTRL, 32'(k), e);
            rd(OFF_CTRL, rdata, e);
            expect_eq(rdata[9], 1'b0, $sformatf("k=%0d VALID cleared before START", k));
            wr(OFF_CTRL, 32'(k) | 32'h10, e);
            rd(OFF_OUT, rdata, e);
            expect_eq(rdata, r[31:0], $sformatf("k=%0d OUT", k));
            rd(OFF_CTRL, rdata, e);
            expect_eq(rdata, ctrl_word(1'b1, r[32], k[2:0]), $sformatf("k=%0d CTRL", k));
        end

        // 3. Мусор в зарезервированных битах при записи
        $display("\n== C: reserved bits ignored ==");
        wr(OFF_CTRL, 32'hFFFF_FFF3, e);          // k=3, START=1, остальное — единицы
        rd(OFF_CTRL, rdata, e);
        expect_eq(rdata, ctrl_word(1'b1, 1'b1, 3'd3), "CTRL with garbage write");
        rd(OFF_OUT, rdata, e);
        expect_eq(rdata, 32'h0000_7071, "OUT with garbage write");
        wr(OFF_CTRL, 32'hFFFF_FFE3, e);          // тот же угол, START=0 — VALID остаётся
        rd(OFF_CTRL, rdata, e);
        expect_eq(rdata, ctrl_word(1'b1, 1'b1, 3'd3), "VALID kept when angle unchanged");

        // 4. Проверка pslverr и неизменности данных
        $display("\n== D: error responses ==");
        wr(OFF_CTRL, 32'h14, e);                 // k=4 -> OUT = 1.0000
        wr(OFF_CTRL, 32'h14, e);
        expect_eq(32'(e), 0, "no error on CTRL write");
        wr(OFF_OUT, 32'hDEAD_BEEF, e);
        expect_eq(32'(e), 1, "error on OUT write");
        rd(OFF_OUT, rdata, e);
        expect_eq(32'(e), 0, "no error on OUT read");
        expect_eq(rdata, 32'h0001_0000, "OUT intact after rejected write");
        wr(4'h8, 32'hFFFF_FFFF, e); expect_eq(32'(e), 1, "error on write 0x8");
        wr(4'hC, 32'hFFFF_FFFF, e); expect_eq(32'(e), 1, "error on write 0xC");
        rd(4'h8, rdata, e);
        expect_eq(32'(e), 1, "error on read 0x8");
        expect_eq(rdata, 32'h0, "read 0x8 returns zero");
        rd(OFF_CTRL, rdata, e);
        expect_eq(rdata, ctrl_word(1'b1, 1'b1, 3'd4), "CTRL intact after bad writes");

        // 5. Случайный прогон с моделью
        $display("\n== E: random sequence with model ==");
        do_reset(3);
        model_reset();
        repeat (400) begin
            int          sel;
            logic [31:0] d;
            bit          exp_err;
            sel = $urandom_range(0, 9);
            d   = $urandom;
            case (sel)
                0, 1, 2, 3: begin                       // запись CTRL
                    d[4] = ($urandom_range(0, 1) == 1);
                    if ($urandom_range(0, 3) == 0) d[2:0] = m_ang;
                    wr(OFF_CTRL, d, e);
                    model_ctrl_write(d);
                    expect_eq(32'(e), 0, "rand: no err on CTRL write");
                end
                4: begin                                // запись в OUT
                    wr(OFF_OUT, d, e);
                    expect_eq(32'(e), 1, "rand: err on OUT write");
                end
                5: begin                                // запись по чужому адресу
                    wr(($urandom_range(0, 1) ? 4'h8 : 4'hC), d, e);
                    expect_eq(32'(e), 1, "rand: err on bad write");
                end
                6, 7: begin                             // чтение CTRL
                    rd(OFF_CTRL, rdata, e);
                    expect_eq(rdata, ctrl_word(m_valid, m_sign, m_ang), "rand: CTRL");
                    expect_eq(32'(e), 0, "rand: no err on CTRL read");
                end
                8: begin                                // чтение OUT
                    rd(OFF_OUT, rdata, e);
                    expect_eq(rdata, m_out, "rand: OUT");
                    expect_eq(32'(e), 0, "rand: no err on OUT read");
                end
                default: begin                          // чтение чужого адреса
                    rd(($urandom_range(0, 1) ? 4'h8 : 4'hC), rdata, e);
                    expect_eq(rdata, 32'h0, "rand: bad read data");
                    expect_eq(32'(e), 1, "rand: err on bad read");
                end
            endcase
        end

        // 6. Сброс посреди работы ---
        $display("\n== F: reset in the middle ==");
        wr(OFF_CTRL, 32'h15, e);                 // k=5, START
        do_reset(3);
        rd(OFF_CTRL, rdata, e); expect_eq(rdata, 32'h0, "CTRL after mid reset");
        rd(OFF_OUT,  rdata, e); expect_eq(rdata, 32'h0, "OUT after mid reset");

        // Итог
        repeat (10) @(posedge pclk);
        $display("\nchecks: %0d, failed: %0d", n_checks, n_fail);
        if (n_fail == 0) $display("=== ALL TESTS PASSED ===");
        else             $display("=== %0d ERRORS ===", n_fail);
        $finish;
    end

    // Страховка от зависания
    initial begin
        #2_000_000;
        $fatal(1, "TIMEOUT");
    end
endmodule
