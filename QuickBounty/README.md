# QuickBounty

Puts the bounties you can hand in at the top of the **Anvil Empires**
bounty board, and removes the pause after handing one in.

**[Download QuickBounty.zip](../../../releases/latest/download/QuickBounty.zip)**
· [How to install](../README.md#installation)
· Author: [Feyn](https://github.com/HarvFeyn)

Version 0.2.0, tested with the Anvil Empires playtest of November 2026 and
`UE4SS_v3.0.1-1181-g83330635`.

## What it does

After you hand in a bounty, the game shows "Bounty complete" over the
bounty list for about two seconds, and you cannot hand in the next one
until it goes away. QuickBounty hides that message as soon as the server
has answered, so you can hand in the next bounty right away. The same goes
for the "Bounty Silver has been transferred" message. Error messages
("Missing one or more items required for this Bounty") stay for one
second, half as long as usual, so you can still read them.

The **withdraw** button shows the final amount at once instead of counting
up, and it is ready as soon as the server has answered: the game kept it
greyed for about two more seconds (closing and opening the window already
skipped that wait).

**Ready bounties first**: the bounties you can hand in right now, with what
you carry, get a gold frame and move to the top of the list. The mod
compares the item each bounty asks for with the items in your inventory.
When the board opens, the list is hidden for about a tenth of a second
while the mod reads every bounty, then shown again, sorted. After a
hand-in, the bounties you can no longer hand in lose their frame at once.

## What it does not do

- It never skips the wait for the server: while the game waits for the
  answer, the window stays blocked as usual.
- It never enables the withdraw button while the game waits for the
  server, and one click sends one request, as in the game.
- It sends nothing by itself and does not change what the game sends: the
  requests are the ones you make with your own clicks.
