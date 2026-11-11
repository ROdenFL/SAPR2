module apb_cos_slave (
    input  logic        pclk,
    input  logic        presetn,
    input  logic [31:0] paddr,
    input  logic [31:0] pwdata,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    output logic        pready,
    output logic        pslverr,
    output logic [31:0] prdata
);
    // Внутренние регистры устройства
    logic [2:0]  angle_sel;   // CTRL[2:0]
    logic        sign_r;      // CTRL[8]
    logic        valid_r;     // CTRL[9]
    logic [31:0] out_reg;     // OUT

    // Локальные константы адресов
    localparam logic [3:0] ADDR_CTRL = 4'h0;
    localparam logic [3:0] ADDR_OUT  = 4'h4;

    // Условия записи и чтения по протоколу APB (фаза ACCESS)
    wire apb_write = psel && penable &&  pwrite;
    wire apb_read  = psel && penable && !pwrite;

    // Таблица cos(k*pi/4): {знак, 8 BCD-тетрад модуля}
    function automatic logic [32:0] cos_rom(input logic [2:0] k);
        case (k)
            3'd0: cos_rom = {1'b0, 32'h0001_0000}; // +1.0000
            3'd1: cos_rom = {1'b0, 32'h0000_7071}; // +0.7071
            3'd2: cos_rom = {1'b0, 32'h0000_0000}; //  0.0000
            3'd3: cos_rom = {1'b1, 32'h0000_7071}; // -0.7071
            3'd4: cos_rom = {1'b1, 32'h0001_0000}; // -1.0000
            3'd5: cos_rom = {1'b1, 32'h0000_7071}; // -0.7071
            3'd6: cos_rom = {1'b0, 32'h0000_0000}; //  0.0000
            3'd7: cos_rom = {1'b0, 32'h0000_7071}; // +0.7071
        endcase
    endfunction

    // Запись в регистры и выполнение операции.
    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            angle_sel <= '0;
            sign_r    <= 1'b0;
            valid_r   <= 1'b0;
            out_reg   <= '0;
        end else if (apb_write) begin
            case (paddr[3:0])
                ADDR_CTRL: begin
                    angle_sel <= pwdata[2:0];
                    if (pwdata[4]) begin                
                        {sign_r, out_reg} <= cos_rom(pwdata[2:0]);
                        valid_r <= 1'b1;
                    end else if (pwdata[2:0] != angle_sel)
                        valid_r <= 1'b0;                  
                end
                default: ;
            endcase
        end
    end

    // Чтение регистров. Работает только в фазе ACCESS при pwrite = 0.
    always_comb begin
        prdata = 32'h0;
        if (apb_read) begin
            case (paddr[3:0])
                ADDR_CTRL: prdata = {22'd0, valid_r, sign_r, 5'd0, angle_sel};
                ADDR_OUT:  prdata = out_reg;
                default:   prdata = 32'h0;
            endcase
        end
    end

    // Готовность только в фазе ACCESS, тактов ожидания нет.
    assign pready  = psel && penable;
    assign pslverr = psel && penable &&
                    ( (paddr[3:0] != ADDR_CTRL && paddr[3:0] != ADDR_OUT) ||
                    (pwrite && paddr[3:0] == ADDR_OUT) );
endmodule
