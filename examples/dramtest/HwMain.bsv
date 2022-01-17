import FIFO::*;
import FIFOF::*;
import Clocks::*;
import Vector::*;

import BRAM::*;
import BRAMFIFO::*;

import PcieCtrl::*;
import DRAMController::*;
import Radix::*;
import Serializer::*;

interface HwMainIfc;
endinterface

module mkHwMain#(PcieUserIfc pcie, DRAMUserIfc dram) 
	(HwMainIfc);

	Clock curClk <- exposeCurrentClock;
	Reset curRst <- exposeCurrentReset;

	Clock pcieclk = pcie.user_clk;
	Reset pcierst = pcie.user_rst;

	//DMASplitterIfc#(4) dma <- mkDMASplitter(pcie);

	Reg#(Bit#(32)) cycles <- mkReg(0);
	rule incCycle;
		cycles <= cycles + 1;
	endrule

	Reg#(Bit#(32)) readBufferSize <- mkReg(0);
	FIFO#(Tuple2#(Bit#(16),Bit#(16))) dramReadReqQ <- mkSizedBRAMFIFO(1024); // offset, words
	Reg#(Bit#(16)) dramReadReqCnt <- mkReg(0);
	Reg#(Bit#(16)) dramReadReqDone <- mkReg(0);
	Reg#(Bit#(16)) dramReqWordLeft <- mkReg(0);
	Reg#(Bit#(16)) dramReqWordOff <- mkReg(0);
	Reg#(Bit#(32)) startCycle <- mkReg(0);
	Reg#(Bit#(32)) elapsedCycle <- mkReg(0);
	rule startDRAMRead(dramReadReqCnt >= 1 && dramReqWordLeft == 0);
		let r = dramReadReqQ.first;
		dramReadReqQ.deq;
		dramReqWordLeft <= tpl_2(r);
		dramReqWordOff <= tpl_1(r);
		dramReadReqDone <= dramReadReqDone + 1;
		if ( dramReadReqDone == 0 ) startCycle <= cycles;
	endrule
	FIFO#(Bool) isLastQ <- mkSizedFIFO(64);
	rule issueDRAMRead (dramReqWordLeft > 0 && readBufferSize < 63);
		dramReqWordLeft <= dramReqWordLeft -1;
		dramReqWordOff <= dramReqWordOff + 1;
		// $write("reading from offset %d\n", dramReqWordOff);
		dram.readReq(zeroExtend(dramReqWordOff)*64, 64);	// Read req 64B = 512b of data at the given offset. read using dram.read
		if ( dramReqWordLeft == 1 && dramReadReqDone == dramReadReqCnt ) isLastQ.enq(True);
		else isLastQ.enq(False);
	endrule
	
	FIFO#(Bit#(512)) readBuffer <- mkSizedBRAMFIFO(64);
	RadixSortIfc rdx <- mkRadixSort; 
	SerializerIfc#(512, 4) srlzr <- mkSerializer;
	rule bufferReads;
		let d <- dram.read;	// 512b data received here (from dram) should be same as 512b data written on lin 175. Because write and read requests made in main.cpp are same
		readBuffer.enq(d);
		readBufferSize <= readBufferSize + 1;
	endrule
	rule serialize;
		readBuffer.deq;
		readBufferSize <= readBufferSize - 1;
		srlzr.put(readBuffer.first); 	// seriliaze into 512/32 = 16 32-bit values
		isLastQ.deq;
		if ( isLastQ.first ) elapsedCycle <= cycles-startCycle;
	endrule
	Reg#(Bit#(32)) ccc <- mkReg(0);
	rule procDRAMRead;
		let d <- srlzr.get;
		rdx.dataIn(d); //Send each 32-bit value into the inQ[0] of RadixSort module using dataIn method
		$write("into radixSorter %d\n", ccc+1);
		ccc <= ccc + 1;
	endrule

	DeSerializerIfc#(128, 4) dsrlzr <- mkDeSerializer;
	Reg#(Bit#(32)) deserializeCount <- mkReg(0);
	FIFO#(Bit#(7)) indexes <- mkFIFO;
	rule  deSerialize;
		let x <- rdx.dataOut; // get i(7-bit), 128-bit using dataOut send it to deserializer
		// Bit#(128) x = 0;
		if(deserializeCount == 0) begin
			Bit#(7) index = truncate(x>>17);
			indexes.enq(index);
			deserializeCount <= 63; // Every 64 (128-bit) elements coming from radix.dataOut will belong to same index
			// $write("index %d\n", index);
		end else begin
			deserializeCount <= deserializeCount - 1;
		end

		let dddd = x;
		Bit#(7) ddd1 = truncate(dddd>>17);
		Bit#(7) ddd2 = truncate(dddd>>49);
		Bit#(7) ddd3 = truncate(dddd>>81);
		Bit#(7) ddd4 = truncate(dddd>>113);
		// $write("%d ", deserializeCount);
		// $write("number's bits %d %d %d %d\n", ddd1, ddd2, ddd3, ddd4);
		dsrlzr.put(x);
	endrule
	// Reg#(Bit#(32)) tempCount <- mkReg(32768);
	// rule  tmp1 (tempCount > 0);
	// 	dsrlzr.put(tempCount);
	// 	$write("tempCount %d\n", tempCount);
	// 	tempCount <= tempCount - 1;
	// endrule
	// rule  tmp2;
	// 	let b <- dsrlzr.get;
	// endrule

	Vector#(128, Reg#(Bit#(32))) bufferByteOffset <- replicateM(mkReg(0));	// Measured in Bytes
	Reg#(Bit#(32)) indexCount <- mkReg(0);
	Reg#(Bit#(32)) tempCount <- mkReg(0);
	Reg#(Bit#(32)) bASEOFFSET <- mkReg(134217728); 	// 134217728 = 128MB;
	Reg#(Bit#(32)) bUFFERSIZE <- mkReg(1048576);	// 1048576 = 1MB;
	rule writeToBuffer;
		// Get 512-bit from Deserializer
		let b <- dsrlzr.get; 
		tempCount <= tempCount + 1;
		// $write("tempCount %d\n", tempCount+1);
		// Buffer number of every 1024B/512b = 16 512-bit numbers is obtained by dequing indexes; offset within buffer indicated by bufferByteOffset
		if(indexCount == 15) begin
			indexes.deq;
			indexCount <= 0;
		end else begin
			indexCount <= indexCount + 1;
		end
		let i = indexes.first;
		dram.write(zeroExtend(bASEOFFSET + (zeroExtend(i))*bUFFERSIZE + bufferByteOffset[i]), b, 64);
		bufferByteOffset[i] <= bufferByteOffset[i] + 64;
		
		// if (bufferByteOffset[indexes.first] >= 1048576) begin
		// 		//stop
		// end	      
	endrule

	Reg#(Bit#(32)) wordReadLeft <- mkReg(0);
	Reg#(Bit#(32)) wordWriteLeft <- mkReg(0);
	Reg#(Bit#(32)) wordWriteReq <- mkReg(0);
	Reg#(Bit#(16)) dramWriteLeft <- mkReg(0);
	Reg#(Bit#(16)) dramWriteOffset <- mkReg(0);
	Reg#(Bit#(32)) dramReadLeft <- mkReg(0);
	Reg#(Bit#(32)) dramWriteStartCycle <- mkReg(0);
	Reg#(Bit#(32)) dramWriteEndCycle <- mkReg(0);
	FIFO#(Tuple2#(Bit#(16),Bit#(16))) dramWriteQ <- mkSizedBRAMFIFO(1024);


	rule getCmd ( wordWriteLeft == 0 );
		let w <- pcie.dataReceive;
		let a = w.addr;
		let d = w.data;
		// $write("address coming: %d\n", a);
		let off = (a>>2);
		if ( off == 0 ) begin
			wordWriteLeft <= d;
			wordWriteReq <= d;
			pcie.dmaWriteReq( 0, truncate(d)); // offset, words
		end else if ( off == 1 ) begin
			pcie.dmaReadReq( 0, truncate(d)); // offset, words
			wordReadLeft <= wordReadLeft + d;
		end else if ( off == 2 ) begin
			dramWriteQ.enq(tuple2(truncate(d>>16), truncate(d)));
			dramWriteStartCycle <= cycles;
		end else if ( off == 3 ) begin
			dramReadReqQ.enq(tuple2(truncate(d>>16), truncate(d)));
			dramReadReqCnt <= dramReadReqCnt + 1;
		end
	endrule

	rule startDRAMWrite(dramWriteLeft == 0);
		dramWriteQ.deq;
		let r = dramWriteQ.first;
		dramWriteLeft <= tpl_2(r);
		dramWriteOffset <= tpl_1(r);
	endrule

	rule dramWrite( dramWriteLeft > 0 );
		dramWriteLeft <= dramWriteLeft - 1;
		dramWriteOffset <= dramWriteOffset + 1;
		Bit#(128) v0 = 128'h11112222333344445555666600000000 | zeroExtend(dramWriteLeft);
		Bit#(128) v1 = 128'hcccccccccccccccccccccccc00000000 | zeroExtend(dramWriteLeft);
		Bit#(128) v2 = 128'hdeadbeefdeadbeeddeadbeef00000000 | zeroExtend(dramWriteLeft);
		Bit#(128) v3 = 128'h88887777666655554444333300000000 | zeroExtend(dramWriteLeft);
		
		// $write("writing at offset %d\n", dramWriteOffset);
		dram.write(zeroExtend(dramWriteOffset)*64, {v0,v1,v2,v3},64);	// Write 64B = 512b data at the offset = dramWriteLeft
		if ( dramWriteLeft == 1 ) begin
			dramWriteEndCycle <= cycles;
		end
	endrule
	//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// rule dramReadReq ( dramReadLeft > 0 );
	// 	dramReadLeft <= dramReadLeft - 1;

	// 	dram.readReq(zeroExtend(dramReadLeft)*64, 64);
	// endrule
	// Reg#(Bit#(512)) dramReadVal <- mkReg(0);
	// rule dramReadResp;
	// 	let d <- dram.read;
	// 	dramReadVal <= d;
	// endrule

	Reg#(DMAWord) lastRecvWord <- mkReg(0);

	rule recvDMAData;
		wordReadLeft <= wordReadLeft - 1;
		let d <- pcie.dmaReadWord;
		lastRecvWord  <= d;
	endrule

	Reg#(Bit#(32)) writeData <- mkReg(0);
	rule sendDMAData ( wordWriteLeft > 0 );
		pcie.dmaWriteData({writeData+3,writeData+2,writeData+1,writeData});
		writeData <= writeData + 4;
		wordWriteLeft <= wordWriteLeft - 1;
	endrule

	rule readStat;
		let r <- pcie.dataReq;
		let a = r.addr;

		// PCIe IO is done at 4 byte granularities
		// lower 2 bits are always zero
		let offset = (a>>2);
		if ( offset == 0 ) begin
			//pcie.dataSend(r, wordWriteLeft);
			pcie.dataSend(r, zeroExtend(dramWriteLeft));
		end else if ( offset == 1 ) begin
			//pcie.dataSend(r, wordWriteReq);
			pcie.dataSend(r, dramReadLeft);
		end else if ( offset == 2 ) begin
			//pcie.dataSend(r, wordReadLeft);
			pcie.dataSend(r, dramWriteEndCycle-dramWriteStartCycle);
		end else begin
			//let noff = (offset-3)*32;
			//pcie.dataSend(r, pcie.debug_data);
			//pcie.dataSend(r, truncate(dramReadVal>>noff));
			pcie.dataSend(r, elapsedCycle);

		end
	endrule

endmodule