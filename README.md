# Friday Nite LIghts
this is an implementation of the 1980 Apple][ game "Tuesday Night Football". The game has been adapted from original source Applesoft source code with Claude and Gemini deconstruction and preparation of the game logic.

This is not a fully exact port -- instead, it implements a similar football game engine for coin flip, play selection for offense and defense, AI decision making, and time management. 

## Features
Apple ][ - type graphics engine and sound engine

Full featured scoreboard with team scores, game clock, play clock, down/yards, and field position

Play-by-play scrolling output

Jumbotron for opening graphics

Marching ants halftime show

## Game start
The game is started with a coin flip. Winner is decided at random with animated kickoff and ball return.

##Offense
The game engine has play selection for various offensive schemes:

* Long pass
* Short Pass
* Play action
* Screen pass
* Run inside
* Run outside
* Pitch
* Trick play
* Punt
* Field Goal

## Defense
There are 8 defensive schemes

* Standard. 4-3
* 8-box run stack
* Pass Blitz
* Nickel
* Dime
* Prevent
* Goal line stand
* Special Teams -- punt or FG block 

## Game decisions
The game engine makes probabillty-based decisions based on 

* play selection
* play matchup
* Indivdual play probabilities
* clock management inside of 2 minutes

## Graphics
Graphics are run in an Apple II engine which simulates a 160 x 80 resolution screen for a low-res look.

* Jumbotron with splash screen
* Animated field with scrimmage and first down lines
* ball movement during pass and kick plays
* Marching Ants halftime show

