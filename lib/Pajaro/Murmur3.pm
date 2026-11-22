# Clojure's Murmur3.java bears the following notice:

# /*
#  * Copyright (C) 2011 The Guava Authors
#  *
#  * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
#  * in compliance with the License. You may obtain a copy of the License at
#  *
#  * http://www.apache.org/licenses/LICENSE-2.0
#  *
#  * Unless required by applicable law or agreed to in writing, software distributed under the License
#  * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
#  * or implied. See the License for the specific language governing permissions and limitations under
#  * the License.
#  */
# 
# /*
#  * MurmurHash3 was written by Austin Appleby, and is placed in the public
#  * domain. The author hereby disclaims copyright to this source code.
#  */
# 
# /*
#  * Source:
#  * http://code.google.com/p/smhasher/source/browse/trunk/MurmurHash3.cpp
#  * (Modified to adapt to Guava coding conventions and to use the HashFunction interface)
#  */
# 
# /**
#  * Modified to remove stuff Clojure doesn't need, placed under clojure.lang namespace,
#  * all fns made static, added hashOrdered/Unordered
#  */

# Adaptations for Pajaro: Copyright (c) 2026 by Phill Wolf

package Pajaro::Murmur3;

use strict;
use integer;
use Encode;

our $seed = 0;
our $C1 = 0xcc9e2d51;
our $C2 = 0x1b873593;

sub int32 {
    my ($x) = @_;
    no integer;
    $x & 0xFFFFFFFF  # keep low 32 bits
}

sub signfix {
    my $x = shift;
    ($x & 0x80000000) ? $x - 0x100000000 : $x;
}

sub rotateLeft { # this sub donated by ChatGPT
    my ($x, $n) = @_;
    int32(($x << $n) | ($x >> (32 - $n)))
}

sub mixK1 {
    my $k1 = shift;
    int32(rotateLeft(int32($k1 * $C1), 15) * $C2)
}

sub mixH1 {
    my $h1 = shift;
    my $k1 = shift;
    int32(rotateLeft($h1 ^ $k1, 13) * 5 + 0xe6546b64)
}

# adapted from Digest::MurmurHash3::PurePerl
sub _fmix32 {
    my $h = shift;
    $h = ( $h ^ ( $h >> 16 ) );
    $h = int32( $h * 0x85ebca6b );
    $h = ( $h ^ ( $h >> 13 ) );
    $h = int32( $h * 0xc2b2ae35 );
    ( $h ^ ( $h >> 16 ) )
}

sub fmix {
    my $h1 = shift;
    my $length = shift;
    _fmix32($h1 ^ $length)
}

sub hash_combine {
    my ($seed, $hash) = @_;
    signfix(int32($seed ^ int32($hash + 0x9e3779b9 + int32($seed << 6) + ($seed >> 2))))
}

sub hashInt {
    my $input = shift;
    if ($input == 0) { return 0; }
    signfix(fmix(mixH1($seed, mixK1($input)),4))
}

sub hashLong_low_high {
    my $low = shift;
    my $high = shift;
    signfix(fmix(mixH1(mixH1($seed, mixK1($low)), mixK1($high)),8))
}

sub hashLong {
    my $input = shift;
    if($input == 0) {return 0}
    my $low = ($input & 0xffffffff);
    my $high = (($input >> 32) & 0xffffffff);
    hashLong_low_high($low, $high)
}

# ClojureScript core.cljs cites http://hg.openjdk.java.net/jdk7u/jdk7u6/jdk/file/8c2c5d63a17e/src/share/classes/java/lang/String.java
sub hasheqString_j {
    my $s = shift;
    if (!defined($s)) {
        0
    }
    else {
        my $len = length($s);
        if ($len == 0) {
            0
        }
        else {
            my $h = 0;
            for (my $i = 0; $i < $len; $i++) {
                $h = ((31 * $h) + ord(substr($s,$i,1)));
                $h = int32($h);
            }
            signfix($h)
        }
    }
}

sub hasheqString {
    my $s = shift;
    hashInt(hasheqString_j($s))
}

sub hashUnencodedChars { # core.cljs
    my $s = shift;
    my $len = length($s);
    my $odd = ($len & 1);
    my $bytes = Encode::encode('UTF-16LE', $s, Encode::FB_CROAK);
    my @vs = unpack('V*v*', $bytes);
    my $leftover = ($odd ? pop(@vs) : undef);
    my $h1 = $seed;
    for my $w (@vs) {
        $h1 = mixH1($h1, mixK1($w));
    }
    if ($odd) {
        $h1 = ($h1 ^ mixK1($leftover))
    }
    signfix(fmix($h1, 2*$len))
}

## note: mirrors Clojure's behavior on the JVM, where the hashCode is
## 1231 for true and 1237 for false
## http://docs.oracle.com/javase/7/docs/api/java/lang/Boolean.html
sub hashBoolean {
    my $b = shift;
    $b ? 1231 : 1237
}

sub hashDouble {
    my $f = shift;
    my $bytes = pack('d', $f);
    my @vs = unpack('V*', $bytes);
    int32($vs[0] ^ $vs[1])
}

sub hashSymbol {
    my $namespace = shift;
    my $name = shift;
    my $nh = hashUnencodedChars($name);
    my $nsh = hasheqString_j($namespace); # the 'wrong' hash.  namespace should be hashed by .hashCode or c.l.Util/hash(NOT hasheq)
    hash_combine($nh, $nsh)
}

sub hashKeyword {
    my $namespace = shift;
    my $name = shift;
    signfix(hashSymbol($namespace, $name) + 0x9e3779b9)
}

sub mixCollHash {
    my $hash = shift;
    my $count = shift;
    my $h1 = $seed;
    my $k1 = mixK1($hash);
    $h1 =mixH1($h1, $k1);
    signfix(fmix($h1, $count))
}

sub hashOrderedIterator {
    my $hashHow = shift;
    my $it = shift;
    my $h = 1; # one
    my $n = 0;
    while ((my $x)=&{$it}()) {
	$h = $h * 31 + &{$hashHow}($x);
	$n++;
    }
    mixCollHash($h, $n)
}

sub hashOrdered {
    my $hashHow = shift;
    my $arr = shift;
    my @arr = @{$arr};
    my $h = 1; # one
    for (my $i=0; $i<@arr; $i++) {
	$h = $h * 31 + &{$hashHow}($arr[$i]);
    }
    mixCollHash($h, 0+@arr)
}

sub hashUnordered {
    my $hashHow = shift;
    my $arr = shift;
    my @arr = @{$arr};
    my $h = 0; # zero
    for (my $i=0; $i<@arr; $i++) {
	$h = $h + &{$hashHow}($arr[$i]);
    }
    mixCollHash($h, 0+@arr)
}

sub hashUnorderedIterator {
    my $hashHow = shift;
    my $it = shift;
    my $h = 0; # zero
    my $n = 0;
    while ((my $x)=&{$it}()) {
	$h = $h + &{$hashHow}($x);
	$n++;
    }
    mixCollHash($h, $n)
}

1;
