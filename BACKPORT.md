$ git rev-list v3.13.7..HEAD --oneline deps/rabbit/src/rabbit_msg_store.erl
f36385408a CQ shared: Fix off-by-nine error leading to lost messages
6008e032f8 Merge pull request #14190 from cloudamqp/msg_store_comment
175ba70e8c [skip ci] Remove rabbit_log and switch to LOG_ macros
6ccfe6a450 Remove outdated comment from rabbit_msg_store
0278980ba0 CQ shared store: Delete from index on remove or roll over (#13959)
7138e8a0cc CQ: Fix rare eof crash of message store with fanout
6cf69e2a19 Fix CQ shared store files not deleted with large messages
fb21a19b72 Optimise msg_store recovery in case of large message file
968eefa1bb Bump (c) line year
639e905aea CQ: Fix shared store scanner missing messages
85e358642b Fix OTP-27 Dialyzer errors in rabbit
d222a36ca2 Additional cleanup following partial FHC removal
5c8366f753 Remove file_handle_cache_stats module
cc73b86e80 CQ: Remove rabbit_msg_store.hrl
41ce4da5ca CQ: Remove ability to change shared store index module
d45fbc3da4 CQ: Write large messages into their own files
18acc01a47 CQ: Make dirty recovery of shared store more efficient
93e4e88872 CQ: Fix entry missing from cache leading to crash on read
fcd011f9cf CQ: Fix shared store crashes
df9f9604e2 CQ: Rewrite the message store file scanning code
2955c4e8e2 CQ: Get messages list from file when doing compaction
e033d97f37 CQ: Defer shared store GC when removes were observed
