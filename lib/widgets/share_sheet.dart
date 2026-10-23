import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/social_repository.dart';
import '../data/chat_repository.dart';
import '../data/twice_media.dart';
import 'verified_badge.dart';

class ShareSheet extends StatefulWidget {
  const ShareSheet({
    super.key,
    required this.postId,
    required this.postCaption,
    required this.postThumbnailUrl,
  });

  final String postId;
  final String postCaption;
  final String postThumbnailUrl;

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _connectedUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  bool _loading = true;
  final Set<String> _sending = {};

  @override
  void initState() {
    super.initState();
    _loadConnectedUsers();
    _search.addListener(_filter);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadConnectedUsers() async {
    try {
      final me = Supabase.instance.client.auth.currentUser?.id;
      if (me == null) return;
      final db = Supabase.instance.client;

      // 1. Get people I follow
      final myFollowing = await db
          .from('follows')
          .select('following_id')
          .eq('follower_id', me)
          .eq('status', 'accepted');
      final followingIds = (myFollowing as List)
          .map((r) => r['following_id'].toString())
          .toSet();

      if (followingIds.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      // 2. Get people who follow me back (mutual)
      final mutualFollowers = await db
          .from('follows')
          .select('follower_id')
          .eq('following_id', me)
          .eq('status', 'accepted')
          .inFilter('follower_id', followingIds.toList());

      final mutualIds = (mutualFollowers as List)
          .map((r) => r['follower_id'].toString())
          .toList();

      if (mutualIds.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      // 3. Fetch their profiles
      final profiles = await db
          .from('profiles')
          .select('id, username, display_name, avatar_url')
          .inFilter('id', mutualIds);

      final users = (profiles as List)
          .map((r) => Map<String, dynamic>.from(r))
          .toList();

      setState(() {
        _connectedUsers = users;
        _filteredUsers = users;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Failed to load connected users: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _search.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredUsers = _connectedUsers;
      } else {
        _filteredUsers = _connectedUsers.where((u) {
          final name = (u['display_name'] ?? '').toString().toLowerCase();
          final username = (u['username'] ?? '').toString().toLowerCase();
          return name.contains(q) || username.contains(q);
        }).toList();
      }
    });
  }

  Future<void> _shareToUser(Map<String, dynamic> user) async {
    final id = user['id'].toString();
    if (_sending.contains(id)) return;

    setState(() => _sending.add(id));
    try {
      final me = Supabase.instance.client.auth.currentUser?.id;
      if (me == null) return;

      // 1. Create or find conversation
      final convId = await SocialRepository.instance.createConversation(id);

      // 2. Build message
      final postUrl = 'https://twice.app/p/${widget.postId}';
      String body = 'Shared a post: $postUrl';
      if (widget.postCaption.isNotEmpty) {
        body = '${widget.postCaption}\n\n$postUrl';
      }

      // 3. Send text
      await ChatRepository.instance.sendText(convId, body);

      // 4. Optionally, we could send the thumbnail as an image here,
      // but sending just the link is cleaner and matches IG behavior.

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sent to ${user['username']}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Container(
      height: media.size.height * 0.75,
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade700,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search connected users',
                hintStyle: const TextStyle(color: Color(0xFFA8A8A8)),
                prefixIcon: const Icon(Icons.search, color: Color(0xFFA8A8A8)),
                filled: true,
                fillColor: const Color(0xFF262626),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filteredUsers.isEmpty
                    ? const Center(
                        child: Text(
                          'No connected users found.\nFollow each other to share.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFFA8A8A8)),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filteredUsers.length,
                        itemBuilder: (context, index) {
                          final user = _filteredUsers[index];
                          final name = (user['display_name'] ?? '').toString();
                          final username = (user['username'] ?? '').toString();
                          final avatar = (user['avatar_url'] ?? '').toString();
                          final isSending = _sending.contains(user['id'].toString());

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: CircleAvatar(
                              radius: 24,
                              backgroundColor: const Color(0xFF262626),
                              backgroundImage: avatar.isNotEmpty ? TwiceThumbCache.get(avatar, targetLongEdge: 128) : null,
                              child: avatar.isEmpty ? const Icon(Icons.person, color: Colors.white) : null,
                            ),
                            title: VerifiedName(
                              userId: user['id'].toString(),
                              name: name,
                              username: username,
                              child: Text(
                                name.isNotEmpty ? name : username,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                            ),
                            subtitle: Text('@$username', style: const TextStyle(color: Color(0xFFA8A8A8))),
                            trailing: isSending
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : TextButton(
                                    onPressed: () => _shareToUser(user),
                                    style: TextButton.styleFrom(
                                      backgroundColor: const Color(0xFF0095F6),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      minimumSize: const Size(0, 32),
                                    ),
                                    child: const Text('Send', style: TextStyle(fontWeight: FontWeight.bold)),
                                  ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
