/// 비웹 플랫폼용 DS Export stub

Future<String> exportDsFromS3({
  required String s3Url,
  required String metaJson,
  required void Function(String stage, double percent) onProgress,
}) async {
  throw UnsupportedError('DS Excel Export는 웹 플랫폼에서만 지원됩니다.');
}

Future<String> exportDsToXlsx({
  required String jsonData,
  required void Function(String stage, double percent) onProgress,
}) async {
  throw UnsupportedError('DS Excel Export는 웹 플랫폼에서만 지원됩니다.');
}

Future<String> downloadXlsxFromUrl({
  required String url,
  required String filename,
  required void Function(String stage, double percent) onProgress,
}) async {
  throw UnsupportedError('DS Excel Export는 웹 플랫폼에서만 지원됩니다.');
}
