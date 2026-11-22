;; Copyright (c) 2026 by Phill Wolf. All rights reserved.
;; The use and distribution terms for this software are covered by the Eclipse Public
;; License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
;; be found in the file epl-v10.html at the root of this distribution.
;; By using this software in any fashion, you are agreeing to be bound by
;; the terms of this license.
;; You must not remove this notice, or any other, from this software.

(ns animal.english
  "English language adapter for the game Guess the Animal"
  (:require [clojure.string :as string]))

(defn a-an [s]
  (string/replace
   s
   #" a\(n\) (.)"
   (fn [[_ c :as x]]
     (if (re-matches #"[aeiouAEIOU]" c)
       (str " an " c)
       (str " a " c)))))

(defn english
  "English version of prompt. 
  The indefinite article a(n) is used."
  [[k params :as _prompt]]
  (a-an
   (case k
     :init
     "Are you thinking of an animal?"

     :node
     (:q params)

     :guess
     (str "Is it a(n) " (:a params) "?")

     :what
     "I give up! What is it?"

     :how
     (str "What question would distinguish a(n) "
          (:right-animal params)
          " from a(n) "
          (:wrong-animal params)
          "?")

     :polarity
     (str "For a(n) " (:right-animal params)
          ", the answer would be...?")

     :learned
     "You have taught me a new animal!\nPlay again?"

     :won
     "I guessed it!\nWould you like to play again?")))

(defn unenglish
  "Removes indefinite article, if any, from the beginning of the string"
  [s]
  (when s
    ;; can't use (?i) for case-blind in Dart
    (string/replace s #"^[aA][nN]? +" "")))

(def valid
  "Parsed answer of the data type befitting the prompt.
  Leading and trailing whitespace in the answer are ignored."
  (let [yes-no (fn [s]
                 (let [t (string/lower-case s)]
                   (cond
                     (re-matches #"^y(es)?$" t)
                     true
                     (re-matches #"^n(o)?$" t)
                     false
                     :else
                     nil)))

        animal-regexes
        [#"[A-Za-z].*" ;; starts with letter
         #"[A-Za-z ]+" ;; consists of letters and space
         #".{2,50}"]   ;; not too long 

        question-regexes
        [#"[A-Za-z].*" ;; starts with letter
         #".*\?"       ;; ends with qmark
         #".*\s.+\?"   ;; more than one word
         #"[-A-Za-z' 0-9]+\?" ;; consists of letters, apos, dash, digits, space
         #".{3,100}"]         ;; not too long

        all-regexes? (fn [regexes s]
                       (when (every?
                              #(re-matches % s)
                              regexes)
                         s))

        animal? (fn [s]
                  (all-regexes? animal-regexes (unenglish s)))]

    (fn valid [[k _params :as _prompt] answer]
      (let [t (string/trim answer)]
        (case k
          (:init :node :guess :polarity :learned :won) (yes-no t)
          :what (animal? t)
          :how (all-regexes? question-regexes t))))))

(defn help
  "Context-sensitive help"
  [[k _params :as _prompt]]
  (case k
    (:init :node :guess :polarity :learned :won)
    "You may answer Yes or No"
    :what
    "Just punch in the word for the animal you are thinking of"
    :how
    "A question, like  Does it bark?"))
