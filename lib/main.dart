import 'dart:ffi';

import 'package:flutter/material.dart';

const ink = Color(0xFF171923);
const muted = Color(0xFF7B8191);
const violet = Color(0xFF7257F5);
const canvas = Color(0xFFF7F7FB);

void main() {
  runApp(const TwiceApp());
}

class NativeCore {
  NativeCore._() {
    try {
      final lib = DynamicLibrary.open('libtwice_native.so');
      _add = lib
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'twice_native_add',
          );
    } catch (_) {
      // Keeps Flutter tests and non-Android preview environments usable.
      _add = null;
    }
  }

  static final NativeCore instance = NativeCore._();

  late final int Function(int, int)? _add;

  int add(int a, int b) => _add?.call(a, b) ?? a + b;

  bool get isLoaded => _add != null;
}

class TwiceApp extends StatelessWidget {
  const TwiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: canvas,
        colorScheme: ColorScheme.fromSeed(
          seedColor: violet,
          brightness: Brightness.light,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: canvas,
          foregroundColor: ink,
          elevation: 0,
          centerTitle: false,
        ),
      ),
      home: const TwiceShell(),
    );
  }
}

class SocialPost {
  SocialPost({
    required this.id,
    required this.name,
    required this.handle,
    required this.initials,
    required this.avatar,
    required this.art,
    required this.caption,
    required this.likes,
    this.liked = false,
  });

  final int id;
  final String name;
  final String handle;
  final String initials;
  final Color avatar;
  final List<Color> art;
  final String caption;
  int likes;
  bool liked;
}

class TwiceShell extends StatefulWidget {
  const TwiceShell({super.key});

  @override
  State<TwiceShell> createState() => _TwiceShellState();
}

class _TwiceShellState extends State<TwiceShell> {
  int selected = 0;
  int nextId = 10;

  final List<SocialPost> posts = [
    SocialPost(
      id: 1,
      name: 'Sofia Bennett',
      handle: '@sofia.b',
      initials: 'SB',
      avatar: const Color(0xFFF0B8A6),
      art: const [Color(0xFFF9C6B4), Color(0xFFE9A2C1)],
      caption:
          'Collect moments, not things. A little sunshine goes a long way ☀️',
      likes: 248,
    ),
    SocialPost(
      id: 2,
      name: 'Marcus Lee',
      handle: '@marcuslee',
      initials: 'ML',
      avatar: const Color(0xFFB8C8F4),
      art: const [Color(0xFF91C9C2), Color(0xFF6E8CD5)],
      caption: 'Slow mornings, good coffee, and absolutely nowhere to rush. ☕',
      likes: 182,
    ),
    SocialPost(
      id: 3,
      name: 'Ava Morgan',
      handle: '@avamorgan',
      initials: 'AM',
      avatar: const Color(0xFFE6C9F2),
      art: const [Color(0xFFB6A0E8), Color(0xFFEDB6D1)],
      caption: 'Make room for the little things that make you happy.',
      likes: 96,
    ),
  ];

  void toggleLike(SocialPost post) {
    setState(() {
      post.liked = !post.liked;
      post.likes += post.liked ? 1 : -1;
    });
  }

  void createPost(String caption) {
    setState(() {
      posts.insert(
        0,
        SocialPost(
          id: nextId++,
          name: 'Your Profile',
          handle: '@you',
          initials: 'Y',
          avatar: violet,
          art: const [Color(0xFFB8A8FF), Color(0xFFEDC0DE)],
          caption: caption,
          likes: 0,
        ),
      );
      selected = 0;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Demo post added to your feed')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      FeedPage(posts: posts, onLike: toggleLike),
      SearchPage(posts: posts),
      CreatePage(onPost: createPost),
      const ActivityPage(),
      ProfilePage(posts: posts),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Twice',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 28),
        ),
        actions: [
          IconButton(
            tooltip: 'Messages',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Messaging will be added later')),
              );
            },
            icon: const Icon(Icons.send_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(index: selected, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFECE7FF),
        onDestinationSelected: (value) => setState(() => selected = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_rounded),
            label: 'Explore',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_box_outlined),
            selectedIcon: Icon(Icons.add_box_rounded),
            label: 'Create',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border_rounded),
            selectedIcon: Icon(Icons.favorite_rounded),
            label: 'Activity',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class FeedPage extends StatelessWidget {
  const FeedPage({super.key, required this.posts, required this.onLike});

  final List<SocialPost> posts;
  final ValueChanged<SocialPost> onLike;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        const StoryStrip(),
        const SizedBox(height: 8),
        ...posts.map((post) => PostCard(post: post, onLike: onLike)),
        const SizedBox(height: 16),
        const Center(
          child: Text('You’re all caught up ✨', style: TextStyle(color: muted)),
        ),
      ],
    );
  }
}

class StoryStrip extends StatelessWidget {
  const StoryStrip({super.key});

  @override
  Widget build(BuildContext context) {
    const names = ['Your story', 'Sofia', 'Marcus', 'Ava', 'Noah', 'Mia'];
    const colors = [
      violet,
      Color(0xFFF0B8A6),
      Color(0xFFB8C8F4),
      Color(0xFFE6C9F2),
      Color(0xFFB4DFCD),
      Color(0xFFF0D18D),
    ];

    return SizedBox(
      height: 105,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: names.length,
        separatorBuilder: (_, _) => const SizedBox(width: 15),
        itemBuilder: (context, i) => SizedBox(
          width: 61,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: i == 0 ? const Color(0xFFD9D5E5) : violet,
                    width: 1.7,
                  ),
                ),
                child: CircleAvatar(
                  radius: 25,
                  backgroundColor: colors[i],
                  child: i == 0
                      ? const Icon(Icons.add, color: Colors.white, size: 28)
                      : Text(
                          names[i][0],
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: ink,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                names[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.post, required this.onLike});

  final SocialPost post;
  final ValueChanged<SocialPost> onLike;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFEDEDF3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: post.avatar,
                  child: Text(
                    post.initials,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: ink,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        post.handle,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'More options',
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
          Container(
            height: 235,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: post.art,
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  top: -35,
                  right: -15,
                  child: Container(
                    width: 175,
                    height: 175,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.17),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  bottom: -70,
                  left: -20,
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Center(
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 66,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
                const Positioned(
                  left: 16,
                  bottom: 15,
                  child: Text(
                    'A MOMENT TO REMEMBER',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 8, 13, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: post.liked ? 'Unlike post' : 'Like post',
                      onPressed: () => onLike(post),
                      icon: Icon(
                        post.liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: post.liked ? Colors.redAccent : ink,
                        size: 25,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Comments',
                      onPressed: () => ScaffoldMessenger.of(context)
                          .showSnackBar(
                            const SnackBar(
                              content: Text('Comments UI will be added later'),
                            ),
                          ),
                      icon: const Icon(Icons.mode_comment_outlined, size: 23),
                    ),
                    IconButton(
                      tooltip: 'Share',
                      onPressed: () => ScaffoldMessenger.of(context)
                          .showSnackBar(
                            const SnackBar(
                              content: Text('Sharing will be added later'),
                            ),
                          ),
                      icon: const Icon(Icons.send_outlined, size: 22),
                    ),
                    const Spacer(),
                    const Icon(Icons.bookmark_border_rounded, size: 24),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Text(
                    '${post.likes} likes',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 5),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${post.handle}  ',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        TextSpan(text: post.caption),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 5),
                  child: Text(
                    'View all comments',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.posts});

  final List<SocialPost> posts;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final results = widget.posts.where((p) {
      final text = '${p.name} ${p.handle} ${p.caption}'.toLowerCase();
      return text.contains(query.toLowerCase());
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'Explore',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 15),
        TextField(
          onChanged: (value) => setState(() => query = value),
          decoration: InputDecoration(
            hintText: 'Search people and posts',
            prefixIcon: const Icon(Icons.search),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 20),
        ...results.map(
          (post) => ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 5),
            leading: CircleAvatar(
              backgroundColor: post.avatar,
              child: Text(post.initials),
            ),
            title: Text(
              post.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(post.caption, maxLines: 2),
          ),
        ),
      ],
    );
  }
}

class CreatePage extends StatefulWidget {
  const CreatePage({super.key, required this.onPost});

  final ValueChanged<String> onPost;

  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Create a post',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          'Share something worth remembering.',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 20),
        Container(
          height: 200,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFB7A5FF), Color(0xFFF0C3DC)],
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_photo_alternate_outlined, size: 45),
              SizedBox(height: 8),
              Text('Photo preview'),
              SizedBox(height: 4),
              Text(
                'Image picking will be added later',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: controller,
          maxLines: 4,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: 'Write a caption...',
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () {
            final caption = controller.text.trim();
            if (caption.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Write a caption first')),
              );
              return;
            }
            widget.onPost(caption);
            controller.clear();
          },
          icon: const Icon(Icons.send_rounded),
          label: const Text('Publish demo post'),
          style: FilledButton.styleFrom(backgroundColor: violet),
        ),
        const SizedBox(height: 10),
        const Text(
          'Demo only: posts remain in memory and disappear when the app restarts.',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 12),
        ),
      ],
    );
  }
}

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        Text(
          'Activity',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900),
        ),
        SizedBox(height: 8),
        Text('Your latest interactions will appear here.'),
        SizedBox(height: 24),
        _ActivityTile(
          initials: 'SB',
          color: Color(0xFFF0B8A6),
          message: 'Sofia shared a little sunshine with her latest post.',
          time: 'Demo activity',
        ),
        _ActivityTile(
          initials: 'ML',
          color: Color(0xFFB8C8F4),
          message: 'Marcus is sharing moments from his day.',
          time: 'Demo activity',
        ),
      ],
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.initials,
    required this.color,
    required this.message,
    required this.time,
  });

  final String initials;
  final Color color;
  final String message;
  final String time;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 7),
      leading: CircleAvatar(backgroundColor: color, child: Text(initials)),
      title: Text(message),
      subtitle: Text(time),
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.posts});

  final List<SocialPost> posts;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Your profile',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 24),
        const Row(
          children: [
            CircleAvatar(
              radius: 38,
              backgroundColor: Color(0xFFDCD2FF),
              child: Icon(Icons.person_rounded, size: 45, color: violet),
            ),
            SizedBox(width: 24),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _ProfileStat(value: '3', label: 'Posts'),
                  _ProfileStat(value: '128', label: 'Followers'),
                  _ProfileStat(value: '96', label: 'Following'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text(
          'Your Name',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
        ),
        const Text(
          'Making every moment count ✨',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Profile editing will be added later'),
            ),
          ),
          child: const Text('Edit profile'),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 8),
        const Row(
          children: [
            Icon(Icons.grid_on_rounded),
            SizedBox(width: 8),
            Text('Your posts', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 14),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: posts.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 6,
            mainAxisSpacing: 6,
          ),
          itemBuilder: (context, i) => Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: posts[i].art),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'C++ core: ${NativeCore.instance.isLoaded ? "connected" : "preview fallback"}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 11),
        ),
        Text(
          'Native check: 2 + 3 = ${NativeCore.instance.add(2, 3)}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 11),
        ),
      ],
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        Text(label, style: const TextStyle(fontSize: 11, color: muted)),
      ],
    );
  }
}
