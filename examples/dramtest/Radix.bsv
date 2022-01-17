package Radix;

import FIFO::*;
import FIFOF::*;
import Vector::*;
import BRAMFIFO::*;

interface RadixSortIfc;
	method Action dataIn(Bit#(128) data);
    method ActionValue#(Bit#(128)) dataOut;
endinterface

module mkRadixSort(RadixSortIfc);

    Vector#(8, FIFO#(Bit#(128))) inQs <- replicateM(mkFIFO);
    Vector#(8, FIFO#(Bit#(128))) inputBufferQ1 <- replicateM(mkSizedBRAMFIFO(10));
    Vector#(8, Reg#(Bit#(32))) q1Count <- replicateM(mkReg(0));
    Vector#(8, FIFO#(Bit#(32))) outputBufferQ2 <- replicateM(mkSizedBRAMFIFO(512));
    Vector#(8, FIFOF#(Bit#(128))) outputBufferQ3 <- replicateM(mkSizedBRAMFIFOF(64));
    Vector#(8, Reg#(Bit#(2))) q3Count <- replicateM(mkReg(0));
    Vector#(8, Vector#(16, FIFO#(Bit#(32)))) dataQs <- replicateM(replicateM(mkSizedBRAMFIFO(512)));
    Vector#(8, FIFOF#(Bit#(128))) outQs <- replicateM(mkFIFOF);
    Vector#(8, Vector#(16, Reg#(Bit#(32)))) dataQInCount <- replicateM(replicateM(mkReg(0)));
    Vector#(8, Vector#(16, Reg#(Bit#(32)))) dataQOutCount <- replicateM(replicateM(mkReg(0)));
    Vector#(8, Reg#(Bit#(32))) dataQburstLeft <- replicateM(mkReg(0));
    Vector#(8, Reg#(Bit#(32))) outputburstLeft <- replicateM(mkReg(0));
    Vector#(8, Reg#(Bit#(3))) fromoutBufferQ <- replicateM(mkReg(0));
    Vector#(8, Reg#(Bit#(128))) outputBuffer <- replicateM(mkReg(0));
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
        rule transferQ1DataQs;
            let d = inputBufferQ1[i].first;
            Bit#(32) element = truncate(d>>(q1Count[i]*32));
            Bit#(7) target = truncate(element>>17);
            let target1 = target/16;
            let target2 = target%16;
            if(target1 == fromInteger(i)) begin
                dataQs[target1][target2].enq(element);
                dataQInCount[target1][target2] <= dataQInCount[target1][target2] + 1;
                // $write("into dataQs[%d] %d\n", target, dataQInCount[target] + 1);
            end
            if(q1Count[i] == 3) begin
                inputBufferQ1[i].deq;
                q1Count[i] <= 0;
            end else begin
                q1Count[i] <= q1Count[i] + 1;
            end
        endrule
    end

    Vector#(8, Reg#(Bit#(4))) ctr <- replicateM(mkReg(0));
    for (Integer i = 0; i < 8; i = i+1) begin
        rule transferDataQstoQ2;
            Bit#(4) idx = ctr[i];
            // $write("rule %d diff for %d = %d\n",  i, idx, dataQInCount[i][idx] - dataQOutCount[i][idx]);
            if(dataQburstLeft[i] == 0) begin
                if(dataQInCount[i][idx] - dataQOutCount[i][idx] >= 256) begin
                    dataQs[i][idx].deq;
                    dataQOutCount[i][idx] <= dataQOutCount[i][idx] + 1;
                    outputBufferQ2[i].enq(dataQs[i][idx].first);
                    // $write("1) from i = %d\n", i);
                    dataQburstLeft[i] <= 255;
                    // $write("1) from %d to %d burst left = %d\n", i, i/16, dataQburstLeft[i/16]);
                end else begin
                    if(ctr[i] == 15) begin
                        ctr[i] <= 0;
                    end else begin
                        ctr[i] <= ctr[i] + 1;                             
                    end
                end
            end else begin
                dataQs[i][idx].deq;
                dataQOutCount[i][idx] <= dataQOutCount[i][idx] + 1;
                outputBufferQ2[i].enq(dataQs[i][idx].first);
                // $write("2 into outQs[%d] %d\n", i, );
                dataQburstLeft[i] <= dataQburstLeft[i] - 1;
                // $write("2) from %d to %d burst left = %d\n", i, i/16, dataQburstLeft[i/16]);
            end
        endrule
    end

    // for (Integer i = 0; i < 128; i = i+1) begin
    //     rule transferDataQstoQ2;
    //         $write("diff for %d = %d\n", i, dataQInCount[i] - dataQOutCount[i]);
    //         if(dataQburstLeft[i/16] == 0) begin
    //             if(dataQInCount[i] - dataQOutCount[i] >= 256) begin
    //                 // dataQs[i].deq;
    //                 // dataQOutCount[i] <= dataQOutCount[i] + 1;
    //                 // outputBufferQ2[i].enq(dataQs[i].first);
    //                 // $write("1) from i = %d\n", i);
    //                 fromdataQ[i/16] <= fromInteger(i);
    //                 dataQburstLeft[i/16] <= 256;
    //                 // $write("1) from %d to %d burst left = %d\n", i, i/16, dataQburstLeft[i/16]);
    //             end
    //         end else begin
    //             if(fromdataQ[i/16] == fromInteger(i)) begin 
    //                 dataQs[i].deq;
    //                 dataQOutCount[i] <= dataQOutCount[i] + 1;
    //                 outputBufferQ2[i].enq(dataQs[i].first);
    //                 // $write("2 into outQs[%d] %d\n", i, );
    //                 dataQburstLeft[i/16] <= dataQburstLeft[i/16] - 1;
    //                 // $write("2) from %d to %d burst left = %d\n", i, i/16, dataQburstLeft[i/16]);
    //             end
    //         end
    //     endrule
    // end

    // for (Integer i = 0; i < 8; i = i+1) begin
    //     rule temppppp;
    //         outputBufferQ2[i].deq;
    //     endrule
    // end

    for (Integer i = 0; i < 8; i = i+1) begin
        rule transferQ2toQ3;
            outputBufferQ2[i].deq;
            // $write("deque %d\n", cc+1);
            let d = outputBufferQ2[i].first;
            if(q3Count[i] == 3) begin
                outputBufferQ3[i].enq({truncate(outputBuffer[i]), d});
                outputBuffer[i] <= 0;
                q3Count[i] <= 0;
            end else begin
                outputBuffer[i] <= (outputBuffer[i]<<32) | zeroExtend(d);
                q3Count[i] <= q3Count[i] + 1;
            end
        endrule
    end


    for (Integer i = 0; i < 8; i = i+1) begin
        rule transferQ3toOutQs;
            if(outputburstLeft[i] == 0) begin
                if(outputBufferQ3[i].notEmpty()) begin    // Flush dataQs[i] when it had more than 1024B of data = 1024B/4B = 256 elements
                    fromoutBufferQ[i] <= 1;
                    outputBufferQ3[i].deq;
                    outQs[i].enq(outputBufferQ3[i].first);
                    // $write("1 into outQs[%d]\n", i);
                    outputburstLeft[i] <= 63;
                end 
                else if(i < 7 && outQs[i+1].notEmpty()) begin
                    fromoutBufferQ[i] <= 0;
                    outQs[i+1].deq;
                    outQs[i].enq(outQs[i+1].first);
                    // $write("1 from outQs[%d] to outQs[%d]\n", i+1, i);
                    outputburstLeft[i] <= 63;
                end
            end else begin
                if(fromoutBufferQ[i] == 1) begin
                    outputBufferQ3[i].deq;
                    outQs[i].enq(outputBufferQ3[i].first);
                    // $write("2 into outQs[%d]\n", i);
                    outputburstLeft[i] <= outputburstLeft[i] - 1;
                end 
                else if(i < 7) begin
                    outQs[i+1].deq;
                    outQs[i].enq(outQs[i+1].first);
                    // $write("2 from outQs[%d] to outQs[%d]\n", i+1, i);
                    outputburstLeft[i] <= outputburstLeft[i] - 1;
                end
            end
        endrule
    end

    // rule temppppp;
    //         outQs[0].deq;
    // endrule
    
    // for (Integer i = 0; i < 8; i = i+1) begin
    //     rule tmeporary;
    //         outputBufferQ3[i].deq;
    //             // outQs[i].deq;
    //             // let d = outQs[0].first;
    //             // outQ0Count <= outQ0Count + 1;
    //             // $write("outQ0count %d index %d\n", outQ0Count + 1, tpl_1(d));
    //     endrule
    // end

    method Action dataIn(Bit#(128) data);
        // Bit#(7) e1 = truncate(data>>17);
        // Bit#(7) e2 = truncate(data>>49);
        // Bit#(7) e3 = truncate(data>>81);
        // Bit#(7) e4 = truncate(data>>113);
        inQs[0].enq(data);
        // inQ0Count <= inQ0Count + 1;
        // $write("inputs %d %d %d %d\n", e1, e2, e3, e4);
    endmethod

    method ActionValue#(Bit#(128)) dataOut;
		outQs[0].deq;
        return outQs[0].first;
	endmethod
endmodule

endpackage : Radix