Pajaro, an experimental Clojure hosted in Perl
=====

Ten years after Rich Hickey came out with Clojure, and five years
after he conceived of transducers as transformers of reducing
functions, he remarked, "Transducers are a fundamental primitive... if
I had Clojure to do all over I would put them at the bottom."
(["History of Clojure" in
HOPL](https://dl.acm.org/doi/10.1145/3386321))

An experiment was in order to see what a transducer bottomed Clojure
might look like.  Clojure is always a hosted language, so a host had
to be identified.

Meanwhile, Perl's motto is "There's more than one way to do it"
(TMTOWTDI, which can be pronounced "tim toady" according to perlfaq1).
How better to put Perl's claim to the test than by doing things
another way? And what way (within the bounds of convenience) could be
more "other" than Clojure?  And what better historical epoch to do it
in, than the era of Perl 5.42?

Pajaro is a melding of those two great software innovations of the
pre-quantum era: Clojure, twisted a bit to wrench transducers into a
foundational spot, and Perl as its skeptical host and beneficiary.

```
make   # Optional: AOT-compiles core for faster sample or REPL startup

perl examples/animal-tty.pl   # Sample .pl bootstrap of a Pajaro program
perl examples/animal-gnome.pl # Sample using CPAN Gnome package

perl pajaro.pl --help

perl pajaro.pl --repl

perl pajaro.pl [--path REQUIRE-DIR:REQUIRE-DIR...] some/directory/my.cljpl

perl pajaro.pl [--path REQUIRE-DIR:REQUIRE-DIR...] --main the.ns.to.run
```

## Language and host interop

The Pajaro language is like [Clojure](https://clojure.org) with a lot of
gaps and distortions (see [Differences from Clojure](#differernces-from-clojure), below).

 - File names:

   1. `.cljpl`
   2. `.cljc` (the reader conditional tag is `:pajaro/cljpl`)
   3. `.clj`

 - Classpath: `require` scans `*path*`, then `@INC`

        (require '[clojure.string :as string])

 - Use Perl data structures (by reference only):

        #perl[1 2 3]            ;; a literal Perl ARRAY
        #perl{"planet" "Earth"} ;; a literal Perl HASH (keys are strings)

        ;; copy a Clojure-ish map to a Perl map
        (reduce-kv assoc! #perl{} {"a" 9 "b" 42})
        ;; copy a Perl map to a Clojure-ish map
        (into {} #perl {"a" 9 "b" 42})

        ;; copy a Clojure-ish vector to a Perl array
        (reduce conj! #perl [] [:a 'fig])
        ;; copy a Perl array to a Clojure-ish vector
        (into [] #perl [:a 'fig])

 - Use Perl builtins. Use the idiom `(vector (fn-that-returns-an-array
   ...))` to capture array results into a Clojure collection.

        (CORE/uc "bOtuLism")
		(vector (CORE/glob "*"))

 - Use Perl infix operators:

        (perl-infix "+" 0.1 7 2/3)

 - Use Perl packages:

        (import '[Data.Dumper])
        (import 'FileHandle)

 - Call subs provided by Perl packages:

        ;; (Package/Method) for Package::Method()
        (println (Data.Dumper/Dumper {:foo "Glarch"}))
        (println (Data.Dumper/Dumper #perl {"baz" "Fudge"}))

        ;; (Package.) for "new Package()"
        ;; (. Package staticMethod arg1 arg2...) for "Package->staticMethod(arg1 arg2)"
        ;; (.method object) for object->method()
        (let [dd (Data.Dumper. #perl[{:foo "Glarch"}])]
          (.Dumper dd))

        ;; (.-member object) for $object->{'member'}
        (let [dd (Data.Dumper. #perl[42])]
          (.-indent dd))

        ;; Perl.Xyz "fully qualifies" 1-segment ref Xyz
        (with-open [fh (Perl.FileHandle. "bird.txt" "w")]
          (binding [*out* fh]
            (println "parrot")))

 - Evaluate Perl text:

        (let [f (perl-eval "sub{my$x=shift; $x+1}")]
          (f 41))

        (perl-statement "use integer")

 - Catch `die` exceptions:

        (try
          (perl-eval "die 'Tilt'")
          (catch :default oops (str "caught " oops)))

 - Extend a protocol to a Perl type (see data types below):

        (extend Perl.ARRAY
          clojure.core/IConj
          {:-conj conj!})

        (conj #perl [:a 6] 3)

### Scalar types

Strings, numbers, and booleans are plain, unboxed Perl scalars, which
have affinity with a Pajaro type for use with protocols and
hierarchies.

| Perl type     | Pajaro type         |
|---------------|---------------------|
| string        | `Pajaro.String`     |
| scalar number | (see Numbers below) |
| boolean       | `Pajaro.Boolean`    |

Perl blessed references are usable as Pajaro types, with a dot as
separator; except that one-leg refs like HASH have a `Perl.` prefix to
remove the ambiguity that they might be relative.

### Blessed references

| Perl type                       | Pajaro type      |
|---------------------------------|------------------|
| package ref (`A::B::C`)         | `A.B.C`          |
| one-word ref (e.g., `HASH`)     | `Perl.HASH`, etc |
| non-ref list, hash (`@a`, `%a`) | n/a              |

### Numbers

Numbers are subtypes of `Pajaro.Number`:

| Clojure-ish literal notation | Perl type          | Pajaro type       |
|------------------------------|--------------------|-------------------|
| `1`                          | (scalar)           | `Pajaro.Long`     |
| `1.1`                        | (scalar)           | `Pajaro.Double`   |
| `1N`                         | `Math::BigInt`     | `Math.BigInt`     |
| `1.1M`                       | `Math::BigFloat`   | `Math.BigFloat`   |
| `1/3`                        | `Math::BigRat`     | `Math.BigRat`     |
| `##-Inf`, `##Inf`, `##NaN`   | (scalar)           | `Pajaro.Double`   |
| `#Math.BigInt "NaN"` etc     | `Math::BigInt` etc | `Math.BigInt` etc |

Perl scalar numbers have affinity with type `Pajaro.Long` or
`Pajaro.Double`, depending on their flags. `Pajaro.Long` encompasses
Perl's unsigned and signed integers, so the postive range is twice as
amazing as the negative range. Refer to `Pajaro.Long/MIN_VALUE`,
`Pajaro.Long/SIGNED_MAX_VALUE`, `Pajaro.Long/MAX_VALUE`.

Scalar numbers' affinity with a Pajaro type is delicate. A Perl scalar
number can carry both integer and float flags, and Perl can set those
flags whenever, e.g., it compares an int to a float or uses a float as
an array index. Pajaro-generated Perl code is supposed to avoid such
pollution. When both int and float flags are set, Pajaro regards the
ambiguous number as a Long.

Perl's floating-point and "Big" number types all have their own NaN,
Inf, and -Inf. Pajaro reads `##Inf` and `##NaN` as Doubles and accepts
reader-literal tags such as `#Math.BigFloat "-Inf"` for the other
numeric types' non-numbers.

### Functions extended to host types

In Clojure tradition, Pajaro extends some core functions to certain
Perl reference types.

For the most part, this is done by extending protocols to host types.
Clojure did not define standard protocols; Pajaro's protocols were
inspired by ClojureScript's. Although these protocols are not a
standard affordance, Pajaro defines the protocols in the clojure.core
namespace because the dispatch functions are proper, documented
members of that namespace.

Keys of Clojure-ish sets and maps must be supported by `=` and `hash`.

| Function    | Extended to interop types                  | Pajaro protocol   |
|-------------|--------------------------------------------|-------------------|
| `=`         | ARRAY, HASH, Regexp, Math.BigFloat,Int,Rat | `IEquiv`          |
| `==`        | Math.BigFloat,Int,Rat                      | -                 |
| `NaN?`      | Math.BigFloat,Int,Rat                      | `IQuot`           |
| `assoc!`    | HASH                                       | `ITransientAssoc` |
| `compare`   | Math.BigFloat,Int,Rat                      | `IComparable`     |
| `conj!`     | ARRAY                                      | `ITransientConj`  |
| `contains?` | ARRAY, HASH                                | `ILookup`         |
| `count`     | ARRAY, HASH                                | `ICount`          |
| `counted?`  | ARRAY, HASH                                | `ICounted`        |
| `dissoc!`   | HASH                                       | `ITransientDisj`  |
| `find`      | ARRAY                                      | `IFind`           |
| `get`       | ARRAY, HASH                                | `ILookup`         |
| `hash`      | ARRAY, HASH, Regexp, Math.BigFloat,Int,Rat | `IHash`           |
| `infinite?` | Math.BigFloat,Int,Rat                      | `INaN`            |
| `keys`      | HASH                                       | `IKeysVals`       |
| `meta`      | CODE                                       | `IMeta`           |
| `mod`       | Math.BigFloat,Int,Rat                      | `IQuot`           |
| `NaN?`      | Math.BigFloat,Int,Rat                      | `INaN`            |
| `neg?`      | Math.BigFloat,Int,Rat                      | `IQuot`           |
| `nth`       | ARRAY                                      | `IIndexed`        |
| `rem`       | Math.BigFloat,Int,Rat                      | `IQuot`           |
| `seq`       | ARRAY, HASH                                | `ISeqable`        |
| `vals`      | HASH                                       | `IKeysVals`       |
| `with-meta` | CODE                                       | `IWithMeta`       |
| `with-open` | FileHandle                                 | `IClose`          |

## Differences from Clojure

Missing features - partial list:

 - The standard library
   - Present: `clojure.string`, `clojure.test`, and their requirements
 - Persistence (instead, structures are copy-on-write)
 - AOT compilation (of anything other than `core.cljpl`)
 - Classloader from a jar file
 - Keywords in aliased namespaces - the two-colon form, as in `::fig/baz`
 - Reducers
 - `array-map`. All maps and sets are in scrambled order
 - `defstruct`, `struct-map`
 - `print-method`
 - `read` (from a stream); `read-string` is present
 - `sorted-map`, `sorted-set`
 - `tap>`
 - Protocols via metadata
 - UUID type (`parse-uuid`, `random-uuid`, `uuid?`)
 - Anything added to Clojure after version 1.12
 - Docstrings that would repeat Clojure's

Host accommodations - aside from those already mentioned:

 - Single thread: No `future`, `agent`, `deliver`, `monitor-enter`, `monitor-exit`, `dosync`, `ref`, etc.
 - Types
   - No character type. Literal `\x` reads as a single-character string. `char?` returns true for a 1-character string. Numeric casts interpret a single-character string as its codepoint. For example: `[(long "0") (parse-long "0")]  =>  [48 0]`
   - No `byte` functions. `int` functions are synonymous with "long" and `float` functions are synonymous with "double"
   - No `definterface`, `reify`
   - Host arrays are not typed, so `into-array` ignores the optional type
 - No arity enforcement for single-arity functions or protocol methods
 - `throw` can throw anything
   - No fundamental "Exception" or "Throwable" type
     - No `ex-cause`
   - The only type allowed in `catch` is `:default`
 - Various
   - Regexes are Perl's
   - `format` is just Perl's `sprintf`
   - No `re-matcher` or `re-groups` (as Perl has no "Matcher")
   - Caution: Perl may call a function named `import` (in any package/namespace) as part of its require/use processing.

Optimizations not ported from Clojure:

 - Chunked sequences
 - Direct linking
 - Arrays as the medium for very small sets and maps
 - Unrolled arities in clojure.core
 - Type hints
 - `volatile`, `vswap!`, etc.; they are aliases for `atom`, `swap!`, etc.

Other differences:

 - No immutability enforcement, especially with interop
 - `make-hierarchy` returns an opaque type, not a Clojure-ish map
 - Variable-arity `&` protocol methods are permitted

## Program overview

 - `pajaro.pl` - Entrypoint and REPL
 - `lib/`
   - `Pajaro.pm` - Perl module: Pajaro type system, protocols, data structures
   - `Pajaro/`
     - `Reader.pm` - Lisp Reader
     - `Transpiler.pm` - Clojure-to-Perl compiler
     - `SourceFilter.pm` - Bootstrap for `.pl` scripts written in Clojure
   - `clojure/` - the in-Clojure part of the standard library
     - `core.cljpl` - clojure.core
	 - `string.cljpl` - clojure.string
	 - `test.cljpl` - clojure.test

## Copyright, Acknowledgments, and License

Copyright (c) 2026 by Phill Wolf. All rights reserved. The use and
distribution terms for this software are covered by the Eclipse Public
License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
be found in the file epl-v10.html at the root of this distribution.
By using this software in any fashion, you are agreeing to be bound by
the terms of this license.  You must not remove this notice, or any
other, from this software.

Some portions written in Clojure were derived from Clojure and
ClojureScript, Copyright (c) Rich Hickey, Eclipse Public License 1.0.

Murmur3.pm was derived from Clojure's Murmur3.java, which cited The Guava
Authors, Apache License 2.0.

I would like to acknowledge the Republican Party for excessive
(and almost sufficient) hobby time for this project.
