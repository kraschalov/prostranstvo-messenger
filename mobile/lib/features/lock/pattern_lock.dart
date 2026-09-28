import 'package:flutter/material.dart';
import 'package:mesenger/core/theme/app_theme.dart';

/// Простой графический ключ 3x3.
class PatternLock extends StatefulWidget {
  final ValueChanged<String> onCompleted;

  const PatternLock({super.key, required this.onCompleted});

  @override
  State<PatternLock> createState() => _PatternLockState();
}

class _PatternLockState extends State<PatternLock> {
  List<int> _points = [];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest.shortestSide;
        return GestureDetector(
          onPanStart: (d) => _add(d.localPosition, size),
          onPanUpdate: (d) => _add(d.localPosition, size),
          onPanEnd: (_) => _finish(),
          child: Container(
            width: size,
            height: size,
            child: Stack(
              children: [
                for (var i = 0; i < 9; i++)
                  Positioned(
                    left: (i % 3) * (size / 3) - 14 + (size / 6),
                    top: (i ~/ 3) * (size / 3) - 14 + (size / 6),
                    child: _dot(i),
                  ),
                if (_points.length >= 2) ..._lines(size),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _dot(int i) {
    final selected = _points.contains(i);
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.accent : AppColors.surfaceAlt,
        border: Border.all(color: selected ? AppColors.accent : AppColors.border, width: 2),
      ),
    );
  }

  List<Widget> _lines(double size) {
    final step = size / 3;
    return [
      CustomPaint(
        size: Size(size, size),
        painter: _LinePainter(
          points: _points
              .map((i) => Offset(
                    (i % 3) * step + step / 2,
                    (i ~/ 3) * step + step / 2,
                  ))
              .toList(),
        ),
      ),
    ];
  }

  void _add(Offset pos, double size) {
    final step = size / 3;
    final col = (pos.dx / step).floor().clamp(0, 2);
    final row = (pos.dy / step).floor().clamp(0, 2);
    final index = row * 3 + col;
    if (!_points.contains(index)) {
      setState(() => _points.add(index));
    }
  }

  void _finish() {
    if (_points.length < 4) {
      setState(() => _points = []);
      return;
    }
    final result = _points.join();
    setState(() => _points = []);
    widget.onCompleted(result);
  }
}

class _LinePainter extends CustomPainter {
  final List<Offset> points;

  _LinePainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LinePainter oldDelegate) =>
      oldDelegate.points != points;
}
