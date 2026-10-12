APP  = pinlock.app
BIN  = $(APP)/Contents/MacOS/pinlock
FW   = -framework Cocoa -framework IOKit -framework Collaboration \
       -framework QuartzCore -framework ServiceManagement -framework Carbon -framework CoreBluetooth \
       -framework CoreMotion -weak_framework ScreenCaptureKit

CERT = pinlock dev
P12  = $${TMPDIR:-/tmp}/pinlock-dev.p12
# The stable identity once `make install` has created it, ad hoc until then.
SIGN = $$(security find-certificate -c "$(CERT)" >/dev/null 2>&1 && echo "$(CERT)" || echo -)

.PHONY: all install uninstall clean cert

all: $(APP)

$(APP): $(BIN) $(APP)/Contents/Info.plist
	codesign -s "$(SIGN)" --force $(APP)
	@touch $(APP)

# macOS ties Bluetooth, Motion and Screen Recording permissions to the app's
# signature. An ad-hoc signature changes with every build, so permissions
# silently stop applying; one stable self-signed identity keeps them. It is
# created once in the login keychain, by `make install`. `security import`
# needs a real file, so the encrypted .p12 sits in $TMPDIR for a moment and is
# removed right away.
cert:
	@security find-certificate -c "$(CERT)" >/dev/null 2>&1 || { \
	  echo "Creating the '$(CERT)' code-signing certificate in your login keychain (one time)"; \
	  umask 077; \
	  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(CERT)" \
	    -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
	    -addext "extendedKeyUsage=critical,codeSigning" -keyout /dev/stdout -out /dev/stdout 2>/dev/null \
	  | /usr/bin/openssl pkcs12 -export -passout pass:pinlock -name "$(CERT)" -out "$(P12)" \
	  && security import "$(P12)" -k login.keychain -f pkcs12 -P pinlock -T /usr/bin/codesign; \
	  status=$$?; rm -f "$(P12)"; exit $$status; }

$(BIN): pinlock.m
	@mkdir -p $(@D)
	clang -fobjc-arc -O2 -Wall $(FW) -o $@ pinlock.m

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(@D)
	cp $< $@

install: cert all
	codesign -s "$(CERT)" --force $(APP)
	@touch $(APP)
	-pkill -x pinlock
	@# pkill returns at once; opening before the old copy is gone fails with -600.
	@for i in $$(seq 50); do pgrep -x pinlock >/dev/null || break; sleep 0.1; done
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	open /Applications/$(APP)

uninstall:
	-pkill -x pinlock
	rm -rf /Applications/$(APP)

clean:
	rm -rf $(APP)
