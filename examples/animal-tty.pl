#!/usr/bin/perl
;;# -*- mode: clojure -*-

;;# Copyright (c) 2026 by Phill Wolf. All rights reserved.
;;# The use and distribution terms for this software are covered by the Eclipse Public
;;# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
;;# be found in the file epl-v10.html at the root of this distribution.
;;# By using this software in any fashion, you are agreeing to be bound by
;;# the terms of this license.
;;# You must not remove this notice, or any other, from this software.

;;use FindBin qw($RealBin);
;;use lib "$RealBin/../lib";
;;use lib "$RealBin/lib";
;;use Pajaro::SourceFilter;

;; "Guess the Animal" game, teletype style

(require '[clojure.string :as string]
         '[animal.core :as animal]
         '[animal.english :as english])

(defn play []
  (println "Think of an animal and I will try to guess it.")
  (println "At any point, you may type /help for suggestions.")
  (let [game (animal/new-game)]
    (loop [game game]
      (when-not (= :exit (:state game))
        (let [prompt (animal/prompt game)]
          (println (english/english prompt))
          (when (= :what (:state game))
            (print "It is a... "))
          (when-let [answer* (read-line)]
          (let [answer (string/trim answer*)]
            (if (= "/help" (string/lower-case answer))
              (do
                (println (english/help prompt))
                (println "Or type /list to see the animals I know.")
                (recur game))
              (if (= "/list" answer)
                (let [animals (animal/animals game)]
                  (println "Animals I know:")
                  (doseq [animal animals]
                    (println "-" animal))
                  (recur game))
                (if-some [v (english/valid prompt answer)]
                  (recur (animal/turn game v))
                  (do
                    (println "What?! Try /help for a hint")
                    (recur game))))))))))
    (println "Goodbye")))

(when-not *compile-files*
  (play))
