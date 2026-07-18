import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/dot_matrix_loaders.dart';

/// Standalone gallery for the experimental dot-matrix loaders.
/// Run with: flutter run -d windows -t lib/dev/loader_gallery.dart
void main() => runApp(const LoaderGallery());

class LoaderGallery extends StatelessWidget {
  const LoaderGallery({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Settings.tacticalVioletTheme.background,
        body: const SingleChildScrollView(
          padding: EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel('Icarus loaders — usable everywhere'),
              Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  _LoaderCard(
                    label: 'Ember spin 24',
                    child: EmberSpinLoader(size: 24, columns: 9),
                  ),
                  _LoaderCard(
                    label: 'Ember spin 32',
                    child: EmberSpinLoader(size: 32),
                  ),
                  _LoaderCard(
                    label: 'Ember spin 48',
                    child: EmberSpinLoader(size: 48, columns: 13),
                  ),
                  _LoaderCard(
                    label: 'Ember spin 96',
                    child: EmberSpinLoader(size: 96, columns: 15),
                  ),
                  _LoaderCard(
                    label: 'Mark 48',
                    child: IcarusMarkLoader(size: 48, columns: 12),
                  ),
                  _LoaderCard(
                    label: 'Mark 140',
                    child: IcarusMarkLoader(size: 140, columns: 18),
                  ),
                ],
              ),
              SizedBox(height: 40),
              _SectionLabel('Unconventional spinners'),
              Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  _LoaderCard(
                    label: 'Flight trail 32',
                    child: FlightTrailLoader(size: 32, columns: 11),
                  ),
                  _LoaderCard(
                    label: 'Flight trail 48',
                    child: FlightTrailLoader(size: 48),
                  ),
                  _LoaderCard(
                    label: 'Flight trail 96',
                    child: FlightTrailLoader(size: 96, columns: 19),
                  ),
                  _LoaderCard(
                    label: 'Feather 48',
                    child: FeatherFallLoader(size: 48),
                  ),
                  _LoaderCard(
                    label: 'Feather 96',
                    child: FeatherFallLoader(size: 96, columns: 17),
                  ),
                  _LoaderCard(
                    label: 'Ember rise 32',
                    child: EmberRiseLoader(size: 32),
                  ),
                  _LoaderCard(
                    label: 'Ember rise 48',
                    child: EmberRiseLoader(size: 48, columns: 13),
                  ),
                  _LoaderCard(
                    label: 'Ping 32',
                    child: PingLoader(size: 32),
                  ),
                  _LoaderCard(
                    label: 'Ping 48',
                    child: PingLoader(size: 48, columns: 13),
                  ),
                ],
              ),
              SizedBox(height: 40),
              _SectionLabel('Experiments'),
              Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  _LoaderCard(label: 'Wing', child: WingDotLoader(size: 140)),
                  _LoaderCard(label: 'Fire', child: FireDotLoader(size: 140)),
                  _LoaderCard(
                    label: 'Fire 48',
                    child: FireDotLoader(size: 48, columns: 11),
                  ),
                  _LoaderCard(label: 'Cube', child: CubeDotLoader(size: 140)),
                  _LoaderCard(label: 'Cute', child: CuteDotLoader(size: 140)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        text,
        style: TextStyle(
          color: Settings.tacticalVioletTheme.mutedForeground,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LoaderCard extends StatelessWidget {
  const _LoaderCard({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 16),
          Text(
            label,
            style: TextStyle(
              color: Settings.tacticalVioletTheme.mutedForeground,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
