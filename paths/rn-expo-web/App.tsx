// App shell — the golden-path skeleton for `rn-expo-web` (#256).
//
// React Native components, exported to the WEB target (`npm run build` →
// `expo export --platform web` → dist/, served by server.ts). Native →
// App Store is a separate, human-gated track, deliberately out of scope.
// Build agents EXTEND this app; the .tsx sources are stored by ts_check
// but gated by the workspace `npm run build` (there is no node-builtin
// JSX checker), so keep the build green — it is the path's compile gate.

import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { FlatList, StyleSheet, Text, View } from 'react-native';

interface PostSummary {
  title: string;
  views: number;
}

export default function App() {
  const [status, setStatus] = useState('checking the API…');
  const [posts, setPosts] = useState<PostSummary[]>([]);

  useEffect(() => {
    (async () => {
      try {
        const health = (await (await fetch('/health')).json()) as { ok?: boolean };
        setStatus(health.ok ? 'API is up.' : 'API answered, but not ok.');
      } catch {
        setStatus('API unreachable — static shell only.');
        return;
      }
      try {
        const data = (await (await fetch('/loom/content')).json()) as { posts?: PostSummary[] };
        if (Array.isArray(data.posts)) setPosts(data.posts);
      } catch {
        // posts are optional decoration; the status line already says enough
      }
    })();
  }, []);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>rn-expo-web</Text>
      <Text style={styles.tagline}>
        React Native, exported to the web by lex-loom&apos;s bootstrap-install golden path.
      </Text>
      <Text style={styles.status}>{status}</Text>
      {posts.length > 0 && (
        <FlatList
          data={posts}
          keyExtractor={(item) => item.title}
          renderItem={({ item }) => (
            <Text style={styles.post}>
              {item.title} ({item.views} views)
            </Text>
          )}
        />
      )}
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f7f7fb',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  title: { fontSize: 28, fontWeight: '600', color: '#1a1a2e' },
  tagline: { marginTop: 8, color: '#555', textAlign: 'center' },
  status: { marginTop: 16, color: '#3b5bdb' },
  post: { marginTop: 8, color: '#1a1a2e' },
});
