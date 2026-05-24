import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';

/// Favorites tab: same grid cards as Recent (with preview images).
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FavoritePeersView();
  }
}
