# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

PERL = perl

CORE_PM = lib/clojure/core.cljpl.pm

PM_FILES = lib/Pajaro.pm \
	$(wildcard lib/Pajaro/*.pm) \
	$(wildcard lib/Pajaro/*/*.pm)

all: $(CORE_PM)

$(CORE_PM): lib/clojure/core.cljpl pajaro.pl $(PM_FILES)
	$(PERL) pajaro.pl --compile

clean:
	rm -f $(CORE_PM)

.PHONY: all clean
