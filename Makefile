BINDIR ?= $(HOME)/bin
SWIFTC := swiftc -O

all: windim windimui

windim: windim.swift
	$(SWIFTC) -o $@ $<

windimui: windimui.swift
	$(SWIFTC) -o $@ $<

install: all
	mkdir -p $(BINDIR)
	install -m 755 bin/dim $(BINDIR)/dim
	@echo "installed $(BINDIR)/dim — set WINDIM_DIR=$(PWD) if you move this checkout"

clean:
	rm -f windim windimui

.PHONY: all install clean
