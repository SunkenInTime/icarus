import 'package:http/http.dart' as http;

class YoutubeHandler {
  static Future<bool> validateYoutubeLink(String youtubeLink) async {
    final response = await http.get(Uri.parse(youtubeLink));
    if (response.statusCode == 200) {
      return true;
    } else {
      return false;
    }
  }

  static String extractYoutubeIdWithTimestamp(String youtubeLink) {
    //Need to check if it isn't already a youtube id
    if ((youtubeLink.contains("youtu.be") ||
            youtubeLink.contains("youtube.com")) ==
        false) {
      return youtubeLink;
    } else {
      final uri = Uri.tryParse(youtubeLink);
      if (uri == null) return youtubeLink;
      final videoId = uri.pathSegments.first;
      final timestamp = uri.queryParameters["t"];
      return "$videoId&t=$timestamp";
    }
  }
}
