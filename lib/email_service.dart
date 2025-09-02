import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart' as smtp;
import 'package:url_launcher/url_launcher.dart' as url;

class EmailService {
  // SMTP configuration
  final String? smtpHost;
  final int? smtpPort;
  final String? smtpUser;
  final String? smtpPass;
  final String? smtpEncryption;
  
  // SendGrid configuration  
  final String? sendgridKey;
  final String? sendgridSender;
  
  // SMTP constructor
  EmailService({
    this.smtpHost,
    this.smtpPort,
    this.smtpUser,
    this.smtpPass,
    this.smtpEncryption,
    this.sendgridKey,
    this.sendgridSender,
  });
  
  // SendGrid constructor
  EmailService.sendgrid({
    required this.sendgridKey,
    required this.sendgridSender,
  }) : smtpHost = null,
       smtpPort = null,
       smtpUser = null,
       smtpPass = null,
       smtpEncryption = null;
  
  Future<void> send({
    required String to,
    required String subject,
    required String text,
  }) async {
    // Try SendGrid first if configured
    if (sendgridKey != null && sendgridSender != null) {
      await _sendViaSendGrid(to: to, subject: subject, text: text);
      return;
    }
    
    // Try SMTP if configured
    if (smtpHost != null && smtpUser != null && smtpPass != null) {
      await _sendViaSMTP(to: to, subject: subject, text: text);
      return;
    }
    
    // Fallback to system mail client
    await _sendViaSystemMailClient(to: to, subject: subject, text: text);
  }
  
  Future<void> _sendViaSendGrid({
    required String to,
    required String subject, 
    required String text,
  }) async {
    final uri = Uri.parse('https://api.sendgrid.com/v3/mail/send');
    
    final body = jsonEncode({
      'personalizations': [{
        'to': [{'email': to}],
        'subject': subject,
      }],
      'from': {'email': sendgridSender},
      'content': [{
        'type': 'text/plain',
        'value': text,
      }],
    });
    
    final response = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $sendgridKey',
        'Content-Type': 'application/json',
      },
      body: body,
    );
    
    if (response.statusCode >= 400) {
      throw Exception('SendGrid error ${response.statusCode}: ${response.body}');
    }
  }
  
  Future<void> _sendViaSMTP({
    required String to,
    required String subject,
    required String text,
  }) async {
    smtp.SmtpServer smtpServer;
    
    // Configure SMTP server based on encryption type
    switch (smtpEncryption?.toLowerCase()) {
      case 'ssl':
        smtpServer = smtp.SmtpServer(
          smtpHost!,
          port: smtpPort ?? 465,
          ssl: true,
          username: smtpUser,
          password: smtpPass,
        );
        break;
      case 'starttls':
        smtpServer = smtp.SmtpServer(
          smtpHost!,
          port: smtpPort ?? 587,
          username: smtpUser,
          password: smtpPass,
        );
        break;
      case 'none':
        smtpServer = smtp.SmtpServer(
          smtpHost!,
          port: smtpPort ?? 25,
          username: smtpUser,
          password: smtpPass,
          allowInsecure: true,
        );
        break;
      default:
        // Default to STARTTLS
        smtpServer = smtp.SmtpServer(
          smtpHost!,
          port: smtpPort ?? 587,
          username: smtpUser,
          password: smtpPass,
        );
    }
    
    final message = mailer.Message()
      ..from = mailer.Address(smtpUser!, 'Teddy Talks')
      ..recipients.add(to)
      ..subject = subject
      ..text = text;
    
    try {
      await mailer.send(message, smtpServer);
    } catch (e) {
      throw Exception('SMTP error: $e');
    }
  }
  
  Future<void> _sendViaSystemMailClient({
    required String to,
    required String subject,
    required String text,
  }) async {
    // Create mailto URL with encoded parameters
    final encodedSubject = Uri.encodeComponent(subject);
    final encodedBody = Uri.encodeComponent(text);
    final mailtoUrl = 'mailto:$to?subject=$encodedSubject&body=$encodedBody';
    
    final uri = Uri.parse(mailtoUrl);
    
    if (await url.canLaunchUrl(uri)) {
      await url.launchUrl(uri);
    } else {
      throw Exception('Could not launch mail client. No email service configured.');
    }
  }
}