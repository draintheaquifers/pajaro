;; Copyright (c) 2026 by Phill Wolf. All rights reserved.
;; The use and distribution terms for this software are covered by the Eclipse Public
;; License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
;; be found in the file epl-v10.html at the root of this distribution.
;; By using this software in any fashion, you are agreeing to be bound by
;; the terms of this license.
;; You must not remove this notice, or any other, from this software.

(ns animal.core
  "State machine for the Guess the Animal game")

(defn new-game
  "Fresh game state"
  []
  {:state :init
   :zoo {[] {:q "Does it swim?"}
         [true] {:a "fish"}
         [false] {:a "bird"}}})

(defn prompt
  "Data structure indicating what information is needed from the player"
  [game]
  (case (:state game)
    :init
    [:init]

    :node
    [:node (get-in game [:zoo (:place game)])]

    :guess
    [:guess (get-in game [:zoo (:place game)])]

    :what
    [:what]

    :how
    [:how {:wrong-animal (get-in game [:zoo (:place game) :a])
           :right-animal (get game :right-animal)}]

    :polarity
    [:polarity (select-keys game [:distinction :right-animal])]

    :learned
    [:learned]

    :won
    [:won]))

(def turn
  "Next game state, having applied a user input to a game state"
  (fn turn [game answer]
    (case (:state game)
      :init
      (if (= true answer)
        (assoc game :state :node, :place [])
        game)

      :node
      (let [place' (conj (:place game) answer)
            state' (if (:q (get-in game [:zoo place']))
                     :node
                     :guess)]
        (assoc game :state state' :place place'))

      :guess
      (if (= true answer)
        (assoc game :state :won)
        (assoc game :state :what))

      :what
      (assoc game :right-animal answer, :state :how)

      :how
      (assoc game :distinction answer, :state :polarity)

      :polarity
      (let [wrong-animal (get-in game [:zoo (:place game) :a])]
        (-> game
            (assoc-in [:zoo (:place game)]
                      {:q (:distinction game)})
            (assoc-in [:zoo (conj (:place game) answer)]
                      {:a (:right-animal game)})
            (assoc-in [:zoo (conj (:place game) (not answer))]
                      {:a wrong-animal})
            (assoc :state :learned)
            (assoc :place [])))

      (:learned :won)
      (if (= true answer)
        (assoc game :state :init)
        (assoc game :state :exit)))))

(defn animals
  "List of known animals"
  [game]
  (->> game
       :zoo
       vals
       (keep :a)
       (sort)))

