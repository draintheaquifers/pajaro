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

;; "Guess the Animal" game, GNOME desktop-window style.
;; Requires Perl's Gtk3 module.
;; This pl script was vibe-coded by Claude.
(require '[clojure.string :as string]
         '[animal.core :as animal]
         '[animal.english :as english])

(import 'Gtk3)

(def yes-no-prompts
  "Prompt kinds answered by Yes or No (the others want typed text)"
  #{:init :node :guess :polarity :learned :won})

(defn list-animals!
  "Pops up a dialog naming the animals the game knows"
  [window game]
  (let [text (str "Animals I know:\n\n"
                  (string/join "\n" (map #(str "• " %)
                                         (animal/animals game))))
        ;; "%s" keeps any % in an animal name from acting as a format
        dialog (Gtk3.MessageDialog. window "destroy-with-parent"
                                    "info" "ok" "%s" text)]
    (.set_title dialog "Animals")
    (.run dialog)
    (.destroy dialog)))

(defn play []
  (Gtk3/init)
  (let [game (atom (animal/new-game))

        window (Gtk3.Window. "toplevel")
        vbox (Gtk3.Box. "vertical" 12)
        question (Gtk3.Label. "")
        status (Gtk3.Label. "")
        entry (Gtk3.Entry.)
        entry-lead (Gtk3.Label. "It is a...")
        ok-button (. Gtk3.Button new_with_mnemonic "_OK")
        text-row (Gtk3.Box. "horizontal" 6)
        yes-button (. Gtk3.Button new_with_mnemonic "_Yes")
        no-button (. Gtk3.Button new_with_mnemonic "_No")
        yes-no-row (Gtk3.Box. "horizontal" 6)
        list-button (. Gtk3.Button new_with_mnemonic "_Animals I know")
        help-button (. Gtk3.Button new_with_mnemonic "_Help")
        tool-row (Gtk3.Box. "horizontal" 6)

        prompt (fn [] (animal/prompt @game))

        refresh!
        (fn refresh! []
          (let [p (prompt)
                yes-no? (contains? yes-no-prompts (first p))]
            (.set_text question (english/english p))
            (.set_text status "")
            (.set_visible yes-no-row yes-no?)
            (.set_visible text-row (not yes-no?))
            (.set_visible entry-lead (= :what (first p)))
            (.set_text entry "")
            (if yes-no?
              (.grab_focus yes-button)
              (.grab_focus entry))))

        respond!
        (fn respond! [v]
          (let [game' (animal/turn @game v)]
            (if (= :exit (:state game'))
              (.destroy window)
              (do
                (reset! game game')
                (refresh!)))))

        submit-text!
        (fn submit-text! [& _]
          (if-some [v (english/valid (prompt) (.get_text entry))]
            (respond! v)
            (.set_text status "What?! Try Help for a hint")))]

    (.set_title window "Guess the Animal")
    (.set_default_size window 460 -1)
    (.set_border_width window 16)

    (.set_line_wrap question true)
    (.set_xalign question 0.0)
    (.set_line_wrap status true)
    (.set_xalign status 0.0)

    (.pack_start text-row entry-lead false false 0)
    (.pack_start text-row entry true true 0)
    (.pack_start text-row ok-button false false 0)
    (.pack_start yes-no-row yes-button false false 0)
    (.pack_start yes-no-row no-button false false 0)
    (.pack_end tool-row help-button false false 0)
    (.pack_end tool-row list-button false false 0)

    (.pack_start vbox (Gtk3.Label. "Think of an animal and I will try to guess it.")
                 false false 0)
    (.pack_start vbox question false false 0)
    (.pack_start vbox yes-no-row false false 0)
    (.pack_start vbox text-row false false 0)
    (.pack_start vbox status false false 0)
    (.pack_end vbox tool-row false false 0)
    (.add window vbox)

    (.signal_connect window "destroy" (fn [& _] (Gtk3/main_quit)))
    (.signal_connect yes-button "clicked" (fn [& _] (respond! true)))
    (.signal_connect no-button "clicked" (fn [& _] (respond! false)))
    (.signal_connect ok-button "clicked" submit-text!)
    (.signal_connect entry "activate" submit-text!)
    (.signal_connect list-button "clicked"
                     (fn [& _] (list-animals! window @game)))
    (.signal_connect help-button "clicked"
                     (fn [& _] (.set_text status (english/help (prompt)))))

    (.show_all window)
    (refresh!)
    (Gtk3/main)
    (println "Goodbye")))

(when-not *compile-files*
  (play))
