import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:file_saver/file_saver.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/analytics.dart';
import '../utils/distance_format.dart';

enum AnalyticsExportFormat {
  csv('CSV', 'csv'),
  excel('Excel', 'xlsx'),
  pdf('PDF report', 'pdf'),
  json('JSON', 'json'),
  geoJson('GeoJSON', 'geojson');

  const AnalyticsExportFormat(this.label, this.extension);
  final String label;
  final String extension;
}

enum AnalyticsDataset {
  overview('Overview'),
  trends('Trends'),
  categories('Categories'),
  schools('Schools'),
  hazards('Hazard locations');

  const AnalyticsDataset(this.label);
  final String label;
}

class AnalyticsExportService {
  const AnalyticsExportService();

  Future<void> export({
    required AnalyticsData data,
    required AnalyticsExportFormat format,
    required Set<AnalyticsDataset> datasets,
  }) async {
    if (datasets.isEmpty) {
      throw ArgumentError('Choose at least one dataset.');
    }
    final bytes = switch (format) {
      AnalyticsExportFormat.csv => _csv(data, datasets),
      AnalyticsExportFormat.excel => _excel(data, datasets),
      AnalyticsExportFormat.pdf => await _pdf(data, datasets),
      AnalyticsExportFormat.json => _json(data, datasets),
      AnalyticsExportFormat.geoJson => _geoJson(data),
    };
    final stamp = DateFormat('yyyyMMdd_HHmm')
        .format(data.generatedAt.toLocal());
    await FileSaver.instance.saveFile(
      name: 'saferoutes_analytics_$stamp',
      bytes: bytes,
      fileExtension: format.extension,
      mimeType: switch (format) {
        AnalyticsExportFormat.csv => MimeType.csv,
        AnalyticsExportFormat.excel => MimeType.microsoftExcel,
        AnalyticsExportFormat.pdf => MimeType.pdf,
        AnalyticsExportFormat.json => MimeType.json,
        AnalyticsExportFormat.geoJson => MimeType.custom,
      },
      customMimeType: format == AnalyticsExportFormat.geoJson
          ? 'application/geo+json'
          : null,
    );
  }

  Uint8List _csv(AnalyticsData data, Set<AnalyticsDataset> datasets) {
    final rows = <List<dynamic>>[];
    void section(String title, List<List<dynamic>> values) {
      if (rows.isNotEmpty) rows.add([]);
      rows
        ..add([title])
        ..addAll(values);
    }

    if (datasets.contains(AnalyticsDataset.overview)) {
      section('Overview', [
        ['Metric', 'Current', 'Previous'],
        ['Unique hazards', data.summary.total, data.previousSummary.total],
        ['Pending', data.summary.pending, data.previousSummary.pending],
        ['Reviewed', data.summary.verified, data.previousSummary.verified],
        ['Resolved', data.summary.resolved, data.previousSummary.resolved],
        [
          'High priority',
          data.summary.highPriority,
          data.previousSummary.highPriority,
        ],
        [
          'Affected schools',
          data.summary.affectedSchools,
          data.previousSummary.affectedSchools,
        ],
        [
          'Resolution rate (%)',
          data.summary.resolutionRate,
          data.previousSummary.resolutionRate,
        ],
        [
          'Average resolution hours',
          data.summary.averageResolutionHours,
          data.previousSummary.averageResolutionHours,
        ],
        [
          'Duplicate reports consolidated',
          data.deduplication.duplicatesRemoved,
          '',
        ],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.trends)) {
      section('Trends', [
        ['Period', 'Total', 'Pending', 'Reviewed', 'Resolved'],
        for (final point in data.trend)
          [
            point.period.toIso8601String(),
            point.total,
            point.pending,
            point.verified,
            point.resolved,
          ],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.categories)) {
      section('Categories', [
        ['Category', 'Count', 'Percentage', 'Previous count'],
        for (final item in data.categories)
          [item.key, item.count, item.percentage, item.previousCount],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.schools)) {
      section('Schools', [
        [
          'School',
          'District',
          'Total',
          'Pending',
          'Reviewed',
          'Resolved',
          'High priority',
          'Average severity',
          'Resolution rate (%)',
          'Average resolution hours',
        ],
        for (final school in data.schools)
          [
            school.name,
            school.district,
            school.total,
            school.pending,
            school.verified,
            school.resolved,
            school.highPriority,
            school.averageSeverity,
            school.resolutionRate,
            school.averageResolutionHours,
          ],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.hazards)) {
      section('Hazard locations', [
        [
          'ID',
          'School',
          'Type',
          'Severity',
          'Status',
          'Latitude',
          'Longitude',
          'First reported',
          'Resolved',
          'Reports consolidated',
          'Distance to school (mi)',
        ],
        for (final marker in data.markers)
          [
            marker.id,
            marker.schoolName,
            marker.type.name,
            marker.severity,
            marker.status.name,
            marker.latitude,
            marker.longitude,
            marker.firstReportedAt.toIso8601String(),
            marker.resolvedAt?.toIso8601String(),
            marker.duplicateCount,
            metersToMiles(marker.distanceToSchoolMeters),
          ],
      ]);
    }
    return Uint8List.fromList(utf8.encode(Csv().encode(rows)));
  }

  Uint8List _excel(AnalyticsData data, Set<AnalyticsDataset> datasets) {
    final workbook = Excel.createExcel();
    final defaultSheet = workbook.getDefaultSheet();
    if (defaultSheet != null) workbook.delete(defaultSheet);

    void addSheet(String name, List<List<Object?>> rows) {
      final sheet = workbook[name];
      for (final row in rows) {
        sheet.appendRow(row.map(_cellValue).toList(growable: false));
      }
      for (var column = 0; column < (rows.firstOrNull?.length ?? 0); column++) {
        sheet.setColumnAutoFit(column);
      }
    }

    if (datasets.contains(AnalyticsDataset.overview)) {
      addSheet('Overview', [
        ['Metric', 'Current', 'Previous'],
        ['Unique hazards', data.summary.total, data.previousSummary.total],
        ['Pending', data.summary.pending, data.previousSummary.pending],
        ['Reviewed', data.summary.verified, data.previousSummary.verified],
        ['Resolved', data.summary.resolved, data.previousSummary.resolved],
        [
          'High priority',
          data.summary.highPriority,
          data.previousSummary.highPriority,
        ],
        [
          'Affected schools',
          data.summary.affectedSchools,
          data.previousSummary.affectedSchools,
        ],
        [
          'Resolution rate (%)',
          data.summary.resolutionRate,
          data.previousSummary.resolutionRate,
        ],
        [
          'Average resolution hours',
          data.summary.averageResolutionHours,
          data.previousSummary.averageResolutionHours,
        ],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.trends)) {
      addSheet('Trends', [
        ['Period', 'Total', 'Pending', 'Reviewed', 'Resolved'],
        for (final point in data.trend)
          [
            point.period.toIso8601String(),
            point.total,
            point.pending,
            point.verified,
            point.resolved,
          ],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.categories)) {
      addSheet('Categories', [
        ['Category', 'Count', 'Percentage', 'Previous count'],
        for (final item in data.categories)
          [item.key, item.count, item.percentage, item.previousCount],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.schools)) {
      addSheet('Schools', [
        [
          'School',
          'District',
          'Total',
          'Pending',
          'Reviewed',
          'Resolved',
          'High priority',
          'Average severity',
          'Resolution rate (%)',
        ],
        for (final school in data.schools)
          [
            school.name,
            school.district,
            school.total,
            school.pending,
            school.verified,
            school.resolved,
            school.highPriority,
            school.averageSeverity,
            school.resolutionRate,
          ],
      ]);
    }
    if (datasets.contains(AnalyticsDataset.hazards)) {
      addSheet('Hazards', [
        [
          'ID',
          'School',
          'Type',
          'Severity',
          'Status',
          'Latitude',
          'Longitude',
          'First reported',
          'Resolved',
          'Reports consolidated',
        ],
        for (final marker in data.markers)
          [
            marker.id,
            marker.schoolName,
            marker.type.name,
            marker.severity,
            marker.status.name,
            marker.latitude,
            marker.longitude,
            marker.firstReportedAt.toIso8601String(),
            marker.resolvedAt?.toIso8601String(),
            marker.duplicateCount,
          ],
      ]);
    }
    final encoded = workbook.encode();
    if (encoded == null) throw StateError('Could not encode Excel workbook.');
    return Uint8List.fromList(encoded);
  }

  Uint8List _json(AnalyticsData data, Set<AnalyticsDataset> datasets) {
    final all = data.toPrivacySafeJson();
    final selected = <String, dynamic>{
      'generated_at': all['generated_at'],
      'range': all['range'],
      'privacy':
          'Reporter identifiers and free-form descriptions are excluded.',
    };
    if (datasets.contains(AnalyticsDataset.overview)) {
      selected['summary'] = all['summary'];
      selected['previous_summary'] = all['previous_summary'];
      selected['deduplication'] = all['deduplication'];
    }
    if (datasets.contains(AnalyticsDataset.trends)) {
      selected['trends'] = all['trend'];
    }
    if (datasets.contains(AnalyticsDataset.categories)) {
      selected['categories'] = all['categories'];
    }
    if (datasets.contains(AnalyticsDataset.schools)) {
      selected['schools'] = all['schools'];
    }
    if (datasets.contains(AnalyticsDataset.hazards)) {
      selected['hazards'] = all['hazards'];
    }
    return Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(selected)),
    );
  }

  Uint8List _geoJson(AnalyticsData data) => Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(data.toGeoJson())),
  );

  Future<Uint8List> _pdf(
    AnalyticsData data,
    Set<AnalyticsDataset> datasets,
  ) async {
    final document = pw.Document(
      title: 'SafeRoutes analytics',
      author: 'SafeRoutes',
      subject: 'Privacy-safe hazard analytics',
    );
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(36),
        header: (context) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'SafeRoutes Analytics',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.Text('Page ${context.pageNumber} of ${context.pagesCount}'),
          ],
        ),
        footer: (_) => pw.Text(
          'Community reports retain their review status. This report excludes private user information.',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
        ),
        build: (_) => [
          pw.SizedBox(height: 12),
          pw.Text(
            'Hazard statistics report',
            style: pw.TextStyle(
              fontSize: 24,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#087F72'),
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            '${DateFormat.yMMMd().format(data.from.toLocal())} - ${DateFormat.yMMMd().format(data.to.toLocal())} | Generated ${DateFormat.yMMMd().add_jm().format(data.generatedAt.toLocal())}',
          ),
          pw.SizedBox(height: 14),
          if (datasets.contains(AnalyticsDataset.overview)) ...[
            _pdfHeading('Overview'),
            pw.Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pdfMetric('Unique hazards', '${data.summary.total}'),
                _pdfMetric('Pending', '${data.summary.pending}'),
                _pdfMetric('Reviewed', '${data.summary.verified}'),
                _pdfMetric('Resolved', '${data.summary.resolved}'),
                _pdfMetric('High priority', '${data.summary.highPriority}'),
                _pdfMetric(
                  'Resolution rate',
                  data.summary.resolutionRate == null
                      ? 'N/A'
                      : '${data.summary.resolutionRate!.toStringAsFixed(1)}%',
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              '${data.deduplication.duplicatesRemoved} duplicate reports consolidated using ${data.deduplication.method}.',
            ),
            pw.SizedBox(height: 16),
          ],
          if (datasets.contains(AnalyticsDataset.trends) &&
              data.trend.isNotEmpty) ...[
            _pdfHeading('Reports over time'),
            _pdfBars(
              data.trend
                  .map(
                    (point) => MapEntry(
                      DateFormat('M/d').format(point.period.toLocal()),
                      point.total,
                    ),
                  )
                  .toList(),
            ),
            pw.SizedBox(height: 16),
          ],
          if (datasets.contains(AnalyticsDataset.categories) &&
              data.categories.isNotEmpty) ...[
            _pdfHeading('Hazard categories'),
            _pdfHorizontalBars(
              data.categories
                  .map(
                    (item) =>
                        MapEntry(item.key.replaceAll('_', ' '), item.count),
                  )
                  .toList(),
            ),
            pw.SizedBox(height: 16),
          ],
          if (datasets.contains(AnalyticsDataset.schools)) ...[
            _pdfHeading('School comparison'),
            pw.TableHelper.fromTextArray(
              headers: const [
                'School',
                'Total',
                'Pending',
                'Reviewed',
                'Resolved',
                'Rate',
              ],
              data: [
                for (final school in data.schools)
                  [
                    school.name,
                    school.total,
                    school.pending,
                    school.verified,
                    school.resolved,
                    '${school.resolutionRate.toStringAsFixed(1)}%',
                  ],
              ],
              headerDecoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#D7F3ED'),
              ),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellStyle: const pw.TextStyle(fontSize: 8),
            ),
            pw.SizedBox(height: 16),
          ],
          if (datasets.contains(AnalyticsDataset.hazards)) ...[
            _pdfHeading('Hazard locations'),
            pw.TableHelper.fromTextArray(
              headers: const [
                'School',
                'Type',
                'Severity',
                'Status',
                'Coordinates',
              ],
              data: [
                for (final marker in data.markers.take(100))
                  [
                    marker.schoolName,
                    marker.type.label,
                    marker.severity,
                    marker.status.label,
                    '${marker.latitude.toStringAsFixed(5)}, ${marker.longitude.toStringAsFixed(5)}',
                  ],
              ],
              headerDecoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#D7F3ED'),
              ),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellStyle: const pw.TextStyle(fontSize: 7),
            ),
            if (data.markers.length > 100)
              pw.Text(
                'PDF table limited to 100 locations. Use CSV, Excel, JSON, or GeoJSON for the complete export.',
              ),
          ],
        ],
      ),
    );
    return document.save();
  }

  pw.Widget _pdfHeading(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
    ),
  );

  pw.Widget _pdfMetric(String label, String value) => pw.Container(
    width: 150,
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey300),
      borderRadius: pw.BorderRadius.circular(6),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          value,
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        pw.Text(
          label,
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
      ],
    ),
  );

  pw.Widget _pdfBars(List<MapEntry<String, int>> values) {
    final maxValue = values.fold<int>(
      1,
      (max, item) => item.value > max ? item.value : max,
    );
    return pw.Container(
      height: 120,
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          for (final item in values.take(20))
            pw.Expanded(
              child: pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 2),
                child: pw.Column(
                  mainAxisAlignment: pw.MainAxisAlignment.end,
                  children: [
                    pw.Text(
                      '${item.value}',
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                    pw.Container(
                      height: 80 * item.value / maxValue,
                      color: PdfColor.fromHex('#087F72'),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text(item.key, style: const pw.TextStyle(fontSize: 6)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  pw.Widget _pdfHorizontalBars(List<MapEntry<String, int>> values) {
    final maxValue = values.fold<int>(
      1,
      (max, item) => item.value > max ? item.value : max,
    );
    return pw.Column(
      children: [
        for (final item in values)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Row(
              children: [
                pw.SizedBox(
                  width: 120,
                  child: pw.Text(
                    item.key,
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ),
                pw.Container(
                  width: 280 * item.value / maxValue,
                  height: 12,
                  color: PdfColor.fromHex('#2D9CDB'),
                ),
                pw.SizedBox(width: 6),
                pw.Text(
                  '${item.value}',
                  style: const pw.TextStyle(fontSize: 8),
                ),
              ],
            ),
          ),
      ],
    );
  }

  CellValue _cellValue(Object? value) => switch (value) {
    null => TextCellValue(''),
    int number => IntCellValue(number),
    double number => DoubleCellValue(number),
    bool flag => BoolCellValue(flag),
    _ => TextCellValue(value.toString()),
  };
}
