LIBPATH =../../
BOARD=kc705
BUILDTOOLS=$(LIBPATH)/buildtools/

BLIBPATH=$(LIBPATH)/../bluelib/src/

CUSTOMBSV= -p +:$(LIBPATH)/dram/src/:$(BLIBPATH):lib:lib/dram:bsv -steps-max-intervals 3000000 +RTS -K80000k -RTS
CUSTOMCPP_BSIM=$(BLIBPATH)/bdpi.cpp

include $(BUILDTOOLS)/Makefile.base


