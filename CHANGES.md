# Changes between the original implementation and the library

## Actor struct formatting

Format actor functions are now implementation dependant, fetch actor callbacks expect a formatted `ActivityPub.Actor`

## Follower collection callbacks

New callback functions `get_follower_local_ids` and `get_following_local_ids` that accepts an actor and returns a list of IDs of that actor's followers/followings

## Other stuff

`mn_pointer_id` is now called `pointer_id` (run `ActivityPub.Migrations.upgrade/0` to rename it in a migration)