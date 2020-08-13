# Changes between the original implentation and the library

## Actor struct formatting

Format actor functions are now implementation dependant, fetch actor callbacks expect a formatted `ActivityPub.Actor`

## Follower collection callbacks

New callback function `get_follower_ap_ids` that accepts an actor and returns a list of AP IDs of that actor's followers.
