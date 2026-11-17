# Roblox Auto-Battler — Code Showcase

A 1v1 multiplayer stickman fighting game on Roblox that I co-developed and published with a friend. It has **5,000+ visits** and makes money through in-game purchases.

**Play it:** https://www.roblox.com/games/78639386897768

The full game lives in a private repository because it's live and its server code needs to stay private. This repo shows a few of the systems behind it.

## The game

- Real-time 1v1 fights: move, jump, double jump, attack, dash, abilities and ultimates, on PC and phones.
- 30+ playable fighters, each with its own ability kit, finisher and balance tuning.
- Arenas with jump-through and breakable platforms, built on a custom 2D physics layer instead of Roblox physics.
- Bots that fill empty matches, with difficulty levels tuned from automated bot-vs-bot test fights.
- Progression and economy: two currencies, crates with published odds, a battle pass, daily quests, playtime gifts and leaderboards.

## Files in this repo

| File | What it shows |
| --- | --- |
| [`src/Physics2D.luau`](src/Physics2D.luau) | Custom 2D collision for the arena: level geometry as axis-aligned boxes, one-way jump-through platforms, and platforms that break and regrow. |
| [`src/Projectiles.luau`](src/Projectiles.luau) | Projectiles simulated in the same 2D space: they stop on walls and platforms, damage breakable platforms, and stay isolated per match so several matches can run at once. |
| [`src/NetTween.luau`](src/NetTween.luau) | A network optimization: instead of the server tweening effect parts every frame (and sending every change to every player), it sends each tween once and every player's computer plays it. |

## Performance work

Fights were lagging for players, so we measured the network traffic and moved cosmetic animation from the server to each player's computer. A bot match dropped from about **24–31 KB/s to 12.5 KB/s**, and peaks from **93 to 39 KB/s**.

## Tools

- **Luau** (strict mode), **Roblox Studio**, **Rojo** + **VS Code**, **Git/GitHub**
- **Claude Code** as an AI pair programmer, guided by a project context file that holds the game's design rules, conventions and testing notes

## My role

I co-designed the game and wrote its design document (combat rules, fighter roster, economy and progression), built and tuned gameplay systems, balanced the fighters, and designed the store-page thumbnails and ads.
