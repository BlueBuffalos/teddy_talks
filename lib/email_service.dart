import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart';

class EmailService {
  // SendGrid (optional)
  final String? sendgridKey;
  final String? sendgridSender;

  // SMTP (recommended, no third-party):
  final String? smtpHost;
  final int? smtpPort;
  final String? smtpUser;
  final String? smtpPass;
  final String smtpEncryption; // 'ssl' | 'starttls' | 'none'

  EmailService({
    // SendGrid
    this.sendgridKey,
    this.sendgridSender,
    // SMTP
    this.smtpHost,
    this.smtpPort,
    this.smtpUser,
    this.smtpPass,
    this.smtpEncryption = 'starttls',
  });

  bool get _hasSmtp =>
      (smtpHost != null && smtpHost!.isNotEmpty && smtpPort != null && smtpUser != null && smtpUser!.isNotEmpty && smtpPass != null && smtpPass!.isNotEmpty);
  bool get _hasSendGrid => sendgridKey != null && sendgridKey!.isNotEmpty && sendgridSender != null && sendgridSender!.isNotEmpty;

  Future<void> send({required String to, required String subject, required String text}) async {
    if (_hasSmtp) {
      await _sendViaSmtp(to: to, subject: subject, text: text);
      return;
    }
    if (_hasSendGrid) {
      await _sendViaSendGrid(to: to, subject: subject, text: text);
      return;
    }
    throw Exception('No email transport configured');
  }

  Future<void> _sendViaSendGrid({required String to, required String subject, required String text}) async {
    final uri = Uri.parse('https://api.sendgrid.com/v3/mail/send');
    final headers = <String, String>{
      'Authorization': 'Bearer $sendgridKey',
      'Content-Type': 'application/json',
    };
    final body = jsonEncode({
      "personalizations": [
        {
          "to": [
            {"email": to}
          ],
          "subject": subject
        }
      ],
      "from": {"email": sendgridSender},
      "content": [
        {"type": "text/plain", "value": text}
      ]
    });

    final resp = await http.post(uri, headers: headers, body: body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final snippet = resp.body.length > 500 ? resp.body.substring(0, 500) : resp.body;
      throw Exception('SendGrid error ${resp.statusCode}: $snippet');
    }
  }

  Future<void> _sendViaSmtp({required String to, required String subject, required String text}) async {
    final server = SmtpServer(
      smtpHost!,
      port: smtpPort ?? 587,
      username: smtpUser!,
      password: smtpPass!,
      ssl: smtpEncryption.toLowerCase() == 'ssl',
      allowInsecure: smtpEncryption.toLowerCase() == 'none',
    );

    final message = mailer.Message()
      ..from = mailer.Address(smtpUser!, '')
      ..recipients.add(to)
      ..subject = subject
      ..text = text;

    try {
      await mailer.send(message, server);
    } on mailer.MailerException catch (e) {
      throw Exception('SMTP send failed: ${e.toString()}');
    }
  }
}
