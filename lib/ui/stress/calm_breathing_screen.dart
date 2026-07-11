import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../design/design.dart';

class CalmBreathingScreen extends StatefulWidget {
  const CalmBreathingScreen({super.key});

  @override
  State<CalmBreathingScreen> createState() => _CalmBreathingScreenState();
}

class _CalmBreathingScreenState extends State<CalmBreathingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  String _phaseText = "Inhale";
  double _coherenceScore = 0.0;
  bool _isActive = false;

  @override
  void initState() {
    super.initState();
    // A standard resonance frequency is ~5.5 breaths per minute.
    // 5.5 breaths/min = ~10.9 seconds per breath cycle.
    // So 5.45 seconds inhale, 5.45 seconds exhale.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5450),
    );

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _phaseText = "Exhale");
        _controller.reverse();
      } else if (status == AnimationStatus.dismissed) {
        setState(() => _phaseText = "Inhale");
        // Simulate increasing coherence as they breathe
        if (_isActive && _coherenceScore < 95.0) {
          setState(() {
            _coherenceScore += 5.0 + (math.Random().nextDouble() * 5);
            if (_coherenceScore > 100) _coherenceScore = 100.0;
          });
        }
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _startBreathing() {
    setState(() {
      _isActive = true;
      _coherenceScore = 40.0; // Starting baseline
    });
    _controller.forward();
  }

  void _stopBreathing() {
    setState(() {
      _isActive = false;
    });
    _controller.stop();
    _controller.value = 0.0;
    setState(() => _phaseText = "Inhale");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, size: 24),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Resonance Breathing',
            style: AppText.h2,
          ),
          const SizedBox(height: Sp.x2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x8),
            child: Text(
              'Sync your breath with the circle to maximize your HRV and lower sympathetic stress.',
              style: AppText.bodySoft,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 64),
          Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // Scale from 1.0 to 2.0
                final scale = 1.0 + (_controller.value * 1.0);
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: DomainAccent.recovery.withValues(alpha: 0.2 + (_controller.value * 0.3)),
                      border: Border.all(
                        color: DomainAccent.recovery,
                        width: 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Transform.scale(
                      scale: 1.0 / scale, // keep text unscaled
                      child: Text(
                        _isActive ? _phaseText : "Ready",
                        style: AppText.h2.copyWith(
                          color: DomainAccent.recovery,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 64),
          if (_isActive) ...[
            Text(
              'Coherence Score',
              style: AppText.caption,
            ),
            const SizedBox(height: Sp.x2),
            Text(
              '${_coherenceScore.toInt()}%',
              style: AppText.h1.copyWith(
                color: _coherenceScore > 80 ? AppColors.good : AppColors.warn,
              ),
            ),
            const SizedBox(height: Sp.x8),
            OutlinedButton(
              onPressed: _stopBreathing,
              child: const Text('Stop Session'),
            ),
          ] else
            FilledButton(
              onPressed: _startBreathing,
              child: const Text('Begin 2-Minute Session'),
            ),
        ],
      ),
    );
  }
}
