"Guess the Animal" for Perl
=====

Here is a reinvention, for Perl, of the "ANIMAL" machine-learning
demonstration published in [Basic Computer Games, Microcomputer
Edition](https://archive.org/details/Basic_Computer_Games_Microcomputer_Edition_1978_Creative_Computing/)
(1978).

    perl animal-tty.pl

    # For Gnome desktops, install Gtk3 with `cpan Gtk3`. Then:
    perl animal-gnome.pl

The `animal-tty.pl` script presents a teletype-style interface like
the original BASIC.  The `animal-gnome.pl` script offers a civilized
dialog with Perl's Gtk3 module. They share a Guess-the-Animal state
machine, whose program code is in the `lib` directory.

"Guess the Animal" is a culturally important work. The present
interpretation liberates it from the lugubrious, tangled BASIC and
recasts it for use in 21st-century inversion-of-control execution
environments.

## Copyright, Acknowledgments, and License

Copyright (c) 2026 by Phill Wolf. All rights reserved. The use and
distribution terms for this software are covered by the Eclipse Public
License 1.0 (https://opensource.org/licenses/eclipse-1.0.php) which can
be found in the file epl-v10.html at the root of this distribution.
By using this software in any fashion, you are agreeing to be bound by
the terms of this license.  You must not remove this notice, or any
other, from this software.

Portions Copyright (c) Rich Hickey, Eclipse Public License 1.0.
Murmur3.pm was derived from Clojure's Murmur3.java, which cited
The Guava Authors, Apache License 2.0.
