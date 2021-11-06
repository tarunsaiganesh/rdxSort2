package Radix;

import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAMFIFO::*;

interface RadixSortIfc;
	method Action dataIn(Bit#(128) data);
    method ActionValue#(Tuple2#(Bit#(7), Bit#(128))) dataOut;
endinterface

module mkRadixSort(RadixSortIfc);

    Vector#(8, FIFO#(Bit#(128))) inQs <- replicateM(mkFIFO);
    Vector#(8, FIFO#(Bit#(128))) inputBufferQ1 <- replicateM(mkSizedBRAMFIFO(10));
    Vector#(128, FIFO#(Bit#(32))) inputBufferQ2 <- replicateM(mkSizedBRAMFIFO(10));
    Vector#(8, Reg#(Bit#(32))) q1Count <- replicateM(mkReg(0));
    Vector#(128, FIFO#(Bit#(128))) dataQs <- replicateM(mkSizedBRAMFIFO(64));
    Vector#(128, FIFOF#(Tuple2#(Bit#(7), Bit#(128)))) outQs <- replicateM(mkFIFOF);
    Vector#(128, Reg#(Bit#(32))) dataQInCount <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(32))) dataQOutCount <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(32))) burstLeft <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(1))) fromdataQ <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(128))) inputBuffer <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(2))) inputBufferCount <- replicateM(mkReg(0));
    // Reg#(Bit#(32)) inQ0Count <- mkReg(0);
    // Reg#(Bit#(32)) outQ0Count <- mkReg(0);
    // Reg#(Bit#(32)) dataSum <- mkReg(0);
    for (Integer i = 0; i < 8; i = i+1) begin
        rule forwardDataIn;
            inQs[i].deq;
            let d = inQs[i].first;
            Bit#(7) target1 = truncate(d>>17);
            Bit#(7) target2 = truncate(d>>49);
            Bit#(7) target3 = truncate(d>>81);
            Bit#(7) target4 = truncate(d>>113);
            if ((target1 >= fromInteger(i)*16 && target1 < fromInteger(i+1)*16) || (target2 >= fromInteger(i)*16 && target2 < fromInteger(i+1)*16)
                || (target3 >= fromInteger(i)*16 && target3 < fromInteger(i+1)*16) || (target4 >= fromInteger(i)*16 && target4 < fromInteger(i+1)*16)) begin
                inputBufferQ1[i].enq(d);
            end
            if (i < 7) begin
                    inQs[i+1].enq(d);
            end
        endrule
    end

    for(Integer i = 0; i < 8; i = i+1) begin
        rule transferQ1ToQ2;
            let d = inputBufferQ1[i].first;
            Bit#(32) element = truncate(d>>(q1Count[i]*32));
            Bit#(7) target = truncate(element>>17);
            if(target >= fromInteger(i)*16 && target < fromInteger(i+1)*16) begin
                inputBufferQ2[target].enq(element);
            end
            if(q1Count[i] == 3) begin
                inputBufferQ1[i].deq;
                q1Count[i] <= 0;
            end else begin
                q1Count[i] <= q1Count[i] + 1;
            end
        endrule
    end

    for(Integer i = 0; i < 128; i = i+1) begin
        rule bufferToDataQs;
                inputBufferQ2[i].deq;
                let d = inputBufferQ2[i].first;
                if(inputBufferCount[i] == 3) begin
                    dataQs[i].enq({truncate(inputBuffer[i]), d});
                    dataQInCount[i] <= dataQInCount[i] + 1;
                    inputBuffer[i] <= 0;
                    inputBufferCount[i] <= 0;
                end else begin
                    inputBuffer[i] <= (inputBuffer[i]<<32) | zeroExtend(d);
                    inputBufferCount[i] <= inputBufferCount[i] + 1;
                end
        endrule
    end

    for (Integer i = 0; i < 128; i = i+1) begin
        rule forwardDataOut;
            if(burstLeft[i] == 0) begin
                if( dataQInCount[i] - dataQOutCount[i] >= 64) begin    // Flush dataQs[i] when it had more than 1024B of data = 1024B/4B = 256 elements
                    fromdataQ[i] <= 1;
                    dataQs[i].deq;
                    outQs[i].enq(tuple2(fromInteger(i), dataQs[i].first));
                    dataQOutCount[i] <= dataQOutCount[i] + 1;
                    // $write("1 into outQs[%d]\n", i);
                    burstLeft[i] <= 63;
                end else if(i < 127 && outQs[i+1].notEmpty()) begin
                    fromdataQ[i] <= 0;
                    outQs[i+1].deq;
                    outQs[i].enq(outQs[i+1].first);
                    // $write("1 from outQs[%d] to outQs[%d]\n", i+1, i);
                    burstLeft[i] <= 63;
                end
            end else begin
                if(fromdataQ[i] == 1) begin
                    dataQs[i].deq;
                    outQs[i].enq(tuple2(fromInteger(i), dataQs[i].first));
                    dataQOutCount[i] <= dataQOutCount[i] + 1;
                    // $write("2 into outQs[%d]\n", i);
                    burstLeft[i] <= burstLeft[i] - 1;
                end else if(i < 127) begin
                    outQs[i+1].deq;
                    outQs[i].enq(outQs[i+1].first);
                    // $write("2 from outQs[%d] to outQs[%d]\n", i+1, i);
                    burstLeft[i] <= burstLeft[i] - 1;
                end
            end
        endrule
    end
    
    // rule tmeporary;
    //         outQs[0].deq;
    //         let d = outQs[0].first;
    //         // outQ0Count <= outQ0Count + 1;
    //         // $write("outQ0count %d index %d\n", outQ0Count + 1, tpl_1(d));
    // endrule

    method Action dataIn(Bit#(128) data);
        inQs[0].enq(data);
        // inQ0Count <= inQ0Count + 1;
        // $write("inQ0count %d\n", inQ0Count + 1);
    endmethod

    method ActionValue#(Tuple2#(Bit#(7), Bit#(128))) dataOut;
		outQs[0].deq;
        return outQs[0].first;
	endmethod
endmodule

endpackage : Radix