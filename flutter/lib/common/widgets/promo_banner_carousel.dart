import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';

String _tr(String key) => platformFFI.translate(key, localeName);

class PromoBannerCarousel extends StatefulWidget {
  const PromoBannerCarousel({super.key, this.height = 250});

  final double height;

  @override
  State<PromoBannerCarousel> createState() => _PromoBannerCarouselState();
}

class _PromoValuePoint {
  final String key;
  final bool highlight;

  const _PromoValuePoint(this.key, [this.highlight = false]);
}

class _PromoSlideData {
  final String titleKey;
  final String subtitleKey;
  final String serviceHighlightKey;
  final List<Color> accentColors;
  final List<_PromoValuePoint> valuePoints;

  const _PromoSlideData({
    required this.titleKey,
    required this.subtitleKey,
    required this.serviceHighlightKey,
    required this.accentColors,
    this.valuePoints = const [],
  });
}

class _PromoBannerCarouselState extends State<PromoBannerCarousel> {
  /// Internal conversion only — UI shows shekels, not USD.
  static const double _kIlsPerUsd = 3.2;
  static final int _kBirthdayYearIls = (120 * _kIlsPerUsd).round();
  static final int _kThreeYearListIls = _kBirthdayYearIls * 3;
  static final int _kThreeYearDealIls = (_kThreeYearListIls * 0.67).round();

  static const int _kAutoplaySeconds = 10;
  static const String _kSpecialOfferConfigUrl =
      'https://seedesktop.com/wp-content/uploads/2026/03/special_offer.txt';
  static const String _kLicensedStaticBannerUrl =
      'https://seedesktop.com/wp-content/uploads/2026/03/SeeDesktop4.png';
  static const List<_PromoSlideData> _slides = [
    _PromoSlideData(
      titleKey: 'promo-carousel-s1-title',
      subtitleKey: 'promo-carousel-s1-subtitle',
      serviceHighlightKey: 'promo-carousel-s1-highlight',
      accentColors: [
        Color(0xFF1D4ED8),
        Color(0xFF0EA5E9),
        Color(0xFFFACC15),
      ],
    ),
    _PromoSlideData(
      titleKey: 'promo-carousel-s2-title',
      subtitleKey: 'promo-carousel-s2-subtitle',
      serviceHighlightKey: 'promo-carousel-s2-highlight',
      accentColors: [
        Color(0xFF2563EB),
        Color(0xFFDC2626),
        Color(0xFFF59E0B),
      ],
    ),
    _PromoSlideData(
      titleKey: 'promo-carousel-s3-title',
      subtitleKey: 'promo-carousel-s3-subtitle',
      serviceHighlightKey: 'promo-carousel-s3-highlight',
      accentColors: [
        Color(0xFF1E40AF),
        Color(0xFFEF4444),
        Color(0xFFEAB308),
      ],
    ),
    _PromoSlideData(
      titleKey: 'promo-carousel-s4-title',
      subtitleKey: 'promo-carousel-s4-subtitle',
      serviceHighlightKey: 'promo-carousel-s4-highlight',
      accentColors: [
        Color(0xFF1D4ED8),
        Color(0xFFDC2626),
        Color(0xFFFACC15),
      ],
      valuePoints: [
        _PromoValuePoint('promo-carousel-vp-tv'),
        _PromoValuePoint('promo-carousel-vp-sd', true),
        _PromoValuePoint('promo-carousel-vp-plans', true),
      ],
    ),
  ];

  late final PageController _pageController;
  Timer? _autoplayTimer;
  Timer? _countdownTimer;
  Timer? _licenseWatchTimer;
  Timer? _offerRefreshTimer;
  int _secondsLeft = 0;
  bool _hasLicense = false;
  bool _showOffer = false;
  String _offerTitle = '';
  DateTime? _offerExpirationUtc;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      viewportFraction: 1,
      initialPage: _slides.length * 1000,
    );
    _refreshLicenseState();
    _licenseWatchTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refreshLicenseState(),
    );
    _refreshOfferConfig();
    _offerRefreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _refreshOfferConfig(),
    );
    _startAutoplay();
    _startCountdown();
  }

  @override
  void dispose() {
    _autoplayTimer?.cancel();
    _countdownTimer?.cancel();
    _licenseWatchTimer?.cancel();
    _offerRefreshTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startAutoplay() {
    _autoplayTimer?.cancel();
    _autoplayTimer = Timer.periodic(
      const Duration(seconds: _kAutoplaySeconds),
      (_) {
        if (!mounted || _hasLicense || !_pageController.hasClients) return;
        _pageController.nextPage(
          duration: const Duration(milliseconds: 460),
          curve: Curves.easeInOut,
        );
      },
    );
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted ||
          _hasLicense ||
          !_showOffer ||
          _offerExpirationUtc == null) {
        return;
      }
      final now = DateTime.now().toUtc();
      final seconds = _offerExpirationUtc!.difference(now).inSeconds;
      if (seconds <= 0) {
        setState(() {
          _showOffer = false;
          _offerTitle = '';
          _secondsLeft = 0;
          _offerExpirationUtc = null;
        });
        return;
      }
      setState(() => _secondsLeft = seconds);
    });
  }

  Future<void> _refreshLicenseState() async {
    final licensed = await hasProLicenseLocal();
    if (!mounted || licensed == _hasLicense) return;
    setState(() {
      _hasLicense = licensed;
    });
  }

  Future<void> _refreshOfferConfig() async {
    if (!mounted || _hasLicense) {
      return;
    }
    try {
      final response = await http
          .get(Uri.parse(_kSpecialOfferConfigUrl))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        _hideOffer();
        return;
      }
      final jsonPayload = _extractJsonPayload(response.body);
      if (jsonPayload == null) {
        _hideOffer();
        return;
      }
      final decoded = jsonDecode(jsonPayload);
      if (decoded is! Map<String, dynamic>) {
        _hideOffer();
        return;
      }
      final isActive = decoded['is_offer_active'] == true;
      final expirationRaw = decoded['expiration_date']?.toString() ?? '';
      final title = decoded['offer_title']?.toString().trim() ?? '';
      final expiration = DateTime.tryParse(expirationRaw)?.toUtc();
      if (!isActive || expiration == null) {
        _hideOffer();
        return;
      }
      final now = DateTime.now().toUtc();
      final remainingSeconds = expiration.difference(now).inSeconds;
      if (remainingSeconds <= 0) {
        _hideOffer();
        return;
      }
      if (!mounted) return;
      setState(() {
        _showOffer = true;
        _offerTitle = title;
        _offerExpirationUtc = expiration;
        _secondsLeft = remainingSeconds;
      });
    } catch (_) {
      _hideOffer();
    }
  }

  String? _extractJsonPayload(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return trimmed;
    }
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return body.substring(start, end + 1).trim();
    }
    return null;
  }

  void _hideOffer() {
    if (!mounted) return;
    setState(() {
      _showOffer = false;
      _offerTitle = '';
      _offerExpirationUtc = null;
      _secondsLeft = 0;
    });
  }

  String _formatCountdown() {
    final days = _secondsLeft ~/ 86400;
    final hours = (_secondsLeft % 86400) ~/ 3600;
    final minutes = (_secondsLeft % 3600) ~/ 60;
    final seconds = _secondsLeft % 60;
    return '$days ${_tr('promo-cd-days')} ${hours.toString().padLeft(2, '0')}${_tr('promo-cd-hours')} '
        '${minutes.toString().padLeft(2, '0')}${_tr('promo-cd-min')} ${seconds.toString().padLeft(2, '0')}${_tr('promo-cd-sec')}';
  }

  Future<void> _openCheckout() async {
    await launchUrl(
      Uri.parse('https://seedesktop.com'),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final baseBg = Theme.of(context).scaffoldBackgroundColor;
    if (_hasLicense) {
      return Container(
        width: double.infinity,
        height: widget.height,
        color: Colors.transparent,
        child: SizedBox(
          width: double.infinity,
          height: widget.height,
          child: Image.network(
            _kLicensedStaticBannerUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      height: widget.height,
      color: baseBg,
      child: SizedBox(
        width: double.infinity,
        height: widget.height,
        child: PageView.builder(
          controller: _pageController,
          itemBuilder: (_, index) {
            final slide = _slides[index % _slides.length];
            return _buildSlide(context, slide, baseBg);
          },
        ),
      ),
    );
  }

  Widget _buildSlide(
      BuildContext context, _PromoSlideData slide, Color fallbackBg) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          color: fallbackBg,
        ),
        CustomPaint(
          painter: _ComputerTexturePainter(),
          child: const SizedBox.expand(),
        ),
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: EdgeInsets.only(
                top: widget.height > 160 ? 18 : 6, right: widget.height > 160 ? 24 : 10),
            child: Opacity(
              opacity: 0.9,
              child: SvgPicture.asset(
                'assets/icon.svg',
                width: widget.height > 160 ? 56 : 32,
                height: widget.height > 160 ? 56 : 32,
              ),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                slide.accentColors[0].withOpacity(0.72),
                slide.accentColors[1].withOpacity(0.58),
                slide.accentColors[2].withOpacity(0.42),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Colors.black.withOpacity(0.56),
                Colors.black.withOpacity(0.36),
                Colors.black.withOpacity(0.16),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.height > 160 ? 28 : 10,
            vertical: widget.height > 160 ? 18 : 6,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tr(slide.titleKey),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: widget.height > 160 ? 28 : 13,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: widget.height > 160 ? 8 : 4),
                    Text(
                      _tr(slide.subtitleKey),
                      style: TextStyle(
                        color: const Color(0xFFE5E7EB),
                        fontSize: widget.height > 160 ? 15 : 10,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: widget.height > 160 ? 4 : 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: widget.height > 160 ? 12 : 4),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.height > 160 ? 12 : 8,
                        vertical: widget.height > 160 ? 8 : 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.26),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: slide.accentColors[2].withOpacity(0.85),
                        ),
                      ),
                      child: Text(
                        _tr(slide.serviceHighlightKey),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: widget.height > 160 ? 12 : 9,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (slide.valuePoints.isNotEmpty)
                      SizedBox(height: widget.height > 160 ? 10 : 4),
                    if (slide.valuePoints.isNotEmpty)
                      Container(
                        constraints: BoxConstraints(
                            maxWidth: widget.height > 160 ? 420 : 200),
                        padding: EdgeInsets.symmetric(
                          horizontal: widget.height > 160 ? 12 : 8,
                          vertical: widget.height > 160 ? 10 : 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _tr('promo-carousel-price-compare'),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: widget.height > 160 ? 12 : 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                              ),
                            ),
                            SizedBox(height: widget.height > 160 ? 6 : 3),
                            for (final point in slide.valuePoints)
                              Padding(
                                padding: EdgeInsets.only(
                                    bottom: widget.height > 160 ? 4 : 2),
                                child: Text(
                                  _tr(point.key),
                                  style: TextStyle(
                                    color: point.highlight
                                        ? const Color(0xFFFDE68A)
                                        : const Color(0xFFE5E7EB),
                                    fontSize: widget.height > 160 ? 13 : 9,
                                    fontWeight: point.highlight
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                    height: 1.15,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(width: widget.height > 160 ? 18 : 6),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_showOffer)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A84FF).withOpacity(0.18),
                        border: Border.all(color: const Color(0xFF6FB6FF)),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x440A84FF),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (_offerTitle.isNotEmpty)
                            SizedBox(
                              width: 260,
                              child: Text(
                                _offerTitle,
                                textAlign: TextAlign.end,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          if (_offerTitle.isNotEmpty) const SizedBox(height: 6),
                          Text(
                            _tr('promo-carousel-offer-ends'),
                            style: TextStyle(
                              color: const Color(0xFFD1D5DB),
                              fontSize: widget.height > 160 ? 12 : 9,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _formatCountdown(),
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: widget.height > 160 ? 22 : 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: widget.height > 160 ? 1.2 : 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_showOffer) const SizedBox(height: 10),
                  if (_showOffer)
                    Container(
                      width: widget.height > 160 ? 320 : 158,
                      padding: EdgeInsets.fromLTRB(
                        widget.height > 160 ? 12 : 6,
                        widget.height > 160 ? 12 : 6,
                        widget.height > 160 ? 12 : 6,
                        widget.height > 160 ? 10 : 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9FAFB).withOpacity(0.97),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x22000000),
                            blurRadius: 10,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: widget.height > 160 ? 12 : 8,
                              vertical: widget.height > 160 ? 10 : 6,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color(0xFFFFE4E8),
                                  Color(0xFFFEF3C7),
                                  Color(0xFFFCE7F3),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x33EC4899),
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.cake_rounded,
                                  color: const Color(0xFFDB2777),
                                  size: widget.height > 160 ? 30 : 20,
                                ),
                                SizedBox(width: widget.height > 160 ? 10 : 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _tr('promo-carousel-birthday-label'),
                                        style: TextStyle(
                                          color: const Color(0xFF9D174D),
                                          fontSize:
                                              widget.height > 160 ? 11 : 8,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.3,
                                        ),
                                      ),
                                      Text(
                                        '$_kBirthdayYearIls ₪',
                                        style: TextStyle(
                                          color: const Color(0xFFBE185D),
                                          fontSize:
                                              widget.height > 160 ? 28 : 16,
                                          fontWeight: FontWeight.w900,
                                          height: 1.05,
                                        ),
                                      ),
                                      Text(
                                        _tr('promo-carousel-birthday-suffix'),
                                        style: TextStyle(
                                          color: const Color(0xFF831843),
                                          fontSize:
                                              widget.height > 160 ? 12 : 8,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: widget.height > 160 ? 10 : 6),
                          Text(
                            _tr('promo-carousel-plans-blurb'),
                            style: TextStyle(
                              color: const Color(0xFF111827),
                              fontSize: widget.height > 160 ? 12 : 9,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                          SizedBox(height: widget.height > 160 ? 6 : 4),
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Text(
                                '$_kThreeYearListIls ₪',
                                style: TextStyle(
                                  color: const Color(0xFF9CA3AF),
                                  fontSize: widget.height > 160 ? 15 : 10,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.lineThrough,
                                  decorationThickness: 2,
                                ),
                              ),
                              Text(
                                '$_kThreeYearDealIls ₪',
                                style: TextStyle(
                                  color: const Color(0xFFDC2626),
                                  fontSize: widget.height > 160 ? 26 : 15,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: widget.height > 160 ? 8 : 5,
                                  vertical: widget.height > 160 ? 4 : 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF16A34A),
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x4416A34A),
                                      blurRadius: 6,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  _tr('promo-carousel-badge-3y33'),
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize:
                                        widget.height > 160 ? 11 : 8,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (_showOffer)
                    SizedBox(height: widget.height > 160 ? 10 : 4),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.height > 160 ? 18 : 10,
                        vertical: widget.height > 160 ? 12 : 6,
                      ),
                      elevation: 8,
                      shadowColor: const Color(0x55DC2626),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _openCheckout,
                    child: Text(
                      _tr('promo-carousel-upgrade-now'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: widget.height > 160 ? 14 : 11,
                      ),
                    ),
                  ),
                  if (_showOffer) ...[
                    SizedBox(height: widget.height > 160 ? 8 : 4),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.height > 160 ? 4 : 0,
                      ),
                      child: Text(
                        _tr('promo-carousel-dismiss-hint'),
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: widget.height > 160 ? 10 : 8,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ComputerTexturePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final iconPaint = Paint()
      ..color = const Color(0xFFBBD5FF).withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final standPaint = Paint()
      ..color = const Color(0xFFBBD5FF).withOpacity(0.14)
      ..style = PaintingStyle.fill;

    const stepX = 92.0;
    const stepY = 74.0;
    const monitorW = 34.0;
    const monitorH = 22.0;

    for (double y = 20; y < size.height + stepY; y += stepY) {
      for (double x = 20; x < size.width + stepX; x += stepX) {
        final screenRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, monitorW, monitorH),
          const Radius.circular(3),
        );
        canvas.drawRRect(screenRect, iconPaint);
        canvas.drawRect(
          Rect.fromLTWH(x + monitorW / 2 - 1.2, y + monitorH + 1.2, 2.4, 5.5),
          standPaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + monitorW / 2 - 8.5, y + monitorH + 6.7, 17, 2.8),
            const Radius.circular(1.4),
          ),
          standPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
