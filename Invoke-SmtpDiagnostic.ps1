#requires -Version 5.1
<#
.SYNOPSIS
Interactive D4A SMTP diagnostics. No mail is sent unless explicitly requested.
.DESCRIPTION
Load the actual dbconfig.js in an isolated Node process, verify its native
transporter first, then try a bounded matrix and independent .NET/Python probes.
The exported SMTP password is carried through redirected process pipes only.
Use the installed application's Node, module directory, environment and account
to reproduce service behavior. Loading dbconfig.js executes its JavaScript.
.EXAMPLE
.\Invoke-SmtpDiagnostic.ps1
.EXAMPLE
.\Invoke-SmtpDiagnostic.ps1 -ConfigPath 'D:\Apps\Decide4Action\Services\API\dbconfig.js'
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Manual,
    [string]$SmtpHost,
    [ValidateRange(1,65535)][int]$Port = 25,
    [PSCredential]$Credential,
    [ValidateSet('none','opportunistic','required','implicit')][string]$TlsMode = 'required',
    [string]$From,
    [string]$NodePath,
    [string]$PythonPath,
    [string]$ModuleDirectory,
    [ValidateRange(3,60)][int]$TimeoutSeconds = 20,
    [switch]$NonInteractive,
    [switch]$NoSendPrompt,
    [string]$ReportPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Worker = $null
$script:Results = New-Object System.Collections.ArrayList
$script:SecretValues = New-Object System.Collections.Generic.List[string]
$script:AuthBlocked = $false
$script:NodeAvailable = $false
$script:TrialCount = 0
$script:Config = $null
$script:Native = $null
$tempRoot = $null
$nodeSource = @'
'use strict';
// Persistent private pipe worker. Only protocol JSON reaches the parent's redirected stdout.
// Application console output, debug logs, Node warnings, and stderr never reach the operator.
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = () => true;
process.stderr.write = () => true;
for (const key of ['log', 'error', 'warn', 'info', 'debug', 'dir', 'trace']) console[key] = () => {};
const path = require('path');
const fs = require('fs');
const Module = require('module');
const tls = require('tls');
const net = require('net');
let mailer, native, original, from, appEnv, current, loadedPath;
const secrets = new Set();
function registerSecrets(value, key = '', depth = 0) {
  if (depth > 8 || value == null) return;
  if (typeof value === 'string' && /pass|secret|token|privatekey/i.test(key)) {
    secrets.add(value); secrets.add(Buffer.from(value).toString('base64'));
  } else if (typeof value === 'object') {
    for (const k of Object.keys(value)) {
      if (['transporter', '_events', 'mailer'].includes(k)) continue;
      registerSecrets(value[k], k, depth + 1);
    }
  }
}
function redact(value) {
  let s = String(value || '');
  for (const secret of secrets) if (secret) s = s.split(secret).join('[REDACTED]');
  return s.replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '').slice(0, 1800);
}
function clone(o) {
  if (!o || typeof o !== 'object' || Buffer.isBuffer(o)) return o;
  if (Array.isArray(o)) return o.map(clone);
  const c = {}; for (const k of Object.keys(o)) c[k] = clone(o[k]); return c;
}
function env(value) {
  if (value == null) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  else process.env.NODE_TLS_REJECT_UNAUTHORIZED = String(value);
}
function certInfo(socket, target) {
  const c = socket.getPeerCertificate();
  if (!c || !c.subject) return;
  const mismatch = tls.checkServerIdentity(target, c);
  current.certificate = {
    subject: c.subject, issuer: c.issuer, validFrom: c.valid_from, validUntil: c.valid_to,
    hostnameValidation: mismatch ? 'FAIL: hostname mismatch' : 'PASS',
    chainValidation: socket.authorized ? 'PASS' : redact(socket.authorizationError || 'not authorized'),
    protocol: socket.getProtocol()
  };
}
// Observe sockets without changing any transport/TLS option or acceptance decision.
const oldTls = tls.connect;
tls.connect = function (...args) {
  if (current) current.stage = 'TLS negotiation';
  const socket = oldTls.apply(this, args);
  const owner = current;
  socket.once('secureConnect', () => {
    if (current !== owner || !current) return;
    current.encrypted = true;
    certInfo(socket, (args[0] || {}).servername || original.host);
    current.stage = 'SMTP handshake';
  });
  return socket;
};
const oldConnect = net.connect;
net.connect = function (...args) {
  const s = oldConnect.apply(this, args); const owner = current;
  s.once('lookup', err => { if (current === owner && current && err) current.stage = 'DNS'; });
  s.once('connect', () => { if (current === owner && current) current.stage = 'SMTP banner'; });
  return s;
};
function classify(err, stage) {
  const s = String(err.message || '');
  if (['ENOTFOUND', 'EAI_AGAIN', 'EDNS'].includes(err.code)) return 'DNS';
  if (/CERT|SELF_SIGNED|VERIFY_LEAF|ISSUER|ALTNAME/.test(err.code || '') || /certificate|self.signed/i.test(s)) return 'Certificate validation';
  if (/STARTTLS/i.test(s) && err.responseCode === 530) return 'STARTTLS';
  if (err.code === 'EAUTH' || /^AUTH/.test(err.command || '')) return 'Authentication';
  if (/STARTTLS/.test(err.command || '') || /STARTTLS/i.test(s)) return 'STARTTLS';
  if (/EHLO|HELO/.test(err.command || '')) return 'EHLO/HELO';
  if (/TLS|SSL|EPROTO/.test(err.code || '') || /TLS|SSL|wrong version|cipher/i.test(s)) return 'TLS negotiation';
  if (err.code === 'ECONNREFUSED' || err.code === 'EHOSTUNREACH') return 'TCP';
  if (err.code === 'ETIMEDOUT') return stage + ' timeout';
  if (err.command === 'CONN') return stage || 'SMTP banner';
  if (err.code === 'EENVELOPE' || /MAIL|RCPT|DATA/.test(err.command || '')) return 'Relay/send restriction';
  return stage || 'Application/Node';
}
const fields = ['secure', 'requireTLS', 'ignoreTLS', 'authMethod', 'name', 'tls.rejectUnauthorized', 'tls.servername', 'tls.minVersion', 'tls.maxVersion', 'tls.ciphers', 'tls.secureProtocol'];
function flat(o) {
  const f = {};
  for (const key of fields) {
    const [a, b] = key.split('.'); const v = b ? o[a] && o[a][b] : o[a];
    if (v !== undefined) f[key] = v;
  }
  return f;
}
function apply(o, patch) {
  for (const key of Object.keys(patch || {})) {
    if (!fields.includes(key)) throw new Error('Unsupported diagnostic setting');
    const [a, b] = key.split('.'); const target = b ? (o[a] || (o[a] = {})) : o;
    if (patch[key] === null) delete target[b || a]; else target[b || a] = patch[key];
  }
}
async function init(req) {
  if (req.configPath) {
    loadedPath = path.resolve(req.configPath);
    // Load modules with the application's normal resolution. No fake dbconfig parser/decryption.
    try {
      const config = require(loadedPath);
      registerSecrets(config);
      native = config.EmailTransporter; from = config.EmailFrom || '';
      if (!native || typeof native.verify !== 'function') return { ok: false, stage: 'Configuration', reason: 'dbconfig.js does not export EmailTransporter.verify().' };
      original = native.options;
      if (!original || typeof original !== 'object' || !native.transporter || !/SMTP/.test(native.transporter.name || ''))
        return { ok: false, stage: 'Configuration', reason: 'The exported transporter is not a supported Nodemailer SMTP transport.' };
      mailer = require(require.resolve('nodemailer', { paths: [path.dirname(loadedPath)] }));
    } catch (e) {
      // Never emit loader exceptions: source excerpts can contain passwords before redaction is possible.
      return { ok: false, stage: 'Application/Node', reason: e.code === 'MODULE_NOT_FOUND' ? 'dbconfig.js dependency is missing. Run beside the installed D4A API with its node_modules.' : 'dbconfig.js could not load. Check its syntax/runtime dependencies in the application environment; raw loader output suppressed.' };
    }
  } else {
    original = req.options; from = req.from || ''; registerSecrets(original);
    try { mailer = require(require.resolve('nodemailer', { paths: [req.moduleDir || process.cwd()] })); }
    catch (_) { return { ok: false, stage: 'Dependency', reason: 'Nodemailer was not found. PowerShell/Python can continue.' }; }
    native = mailer.createTransport(original);
  }
  registerSecrets(original);
  const a = original.auth || {};
  if (a.user && a.pass) secrets.add(Buffer.from('\0' + a.user + '\0' + a.pass).toString('base64'));
  appEnv = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  const effective = native.transporter.options || original;
  // Credential fields are private IPC only. The parent must not serialize this object into a report.
  return { ok: true, host: effective.host || original.host || 'localhost', port: effective.port || (effective.secure ? 465 : 587),
    user: a.user || '', password: a.pass || '', authType: a.type || 'login', from,
    fields: flat(original), environment: appEnv == null ? null : appEnv,
    effectiveSecure: effective.secure === undefined ? Number(effective.port) === 465 : !!effective.secure,
    customTls: Object.keys(original.tls || {}).filter(k => !['rejectUnauthorized', 'servername'].includes(k)),
    customOptions: ['proxy', 'getSocket', 'connection', 'localAddress', 'service', 'customAuth'].filter(k => original[k] != null),
    nodeVersion: process.version, nodemailerVersion: mailer.version || 'installed application version',
    extraCA: !!process.env.NODE_EXTRA_CA_CERTS };
}
async function test(req) {
  let transport;
  const options = clone(original);
  env(appEnv);
  if (Object.prototype.hasOwnProperty.call(req, 'environment')) env(req.environment);
  if (req.kind === 'native') transport = native;
  else { apply(options, req.patch); transport = mailer.createTransport(options); }
  current = { ok: false, stage: 'TCP', encrypted: false, authenticated: false };
  try {
    if (req.send) {
      const info = await transport.sendMail({ from: req.from || from, to: req.to,
        subject: 'D4A SMTP diagnostic test', text: 'Operator-requested SMTP diagnostic message.' });
      current.acceptedCount = (info.accepted || []).length;
      current.rejectedCount = (info.rejected || []).length;
      if (!current.acceptedCount || current.rejectedCount) throw Object.assign(new Error('SMTP recipient acceptance incomplete'), { code: 'EENVELOPE' });
    } else await transport.verify();
    current.ok = true; current.stage = 'Complete'; current.authenticated = !!(original.auth && original.auth.user);
    current.reason = req.send ? 'SMTP server accepted the test message; mailbox delivery is not proven' :
      current.authenticated ? 'Authentication succeeded' : 'Connection verified; no credentials configured';
  } catch (e) {
    current.stage = classify(e, current.stage);
    current.code = redact(e.code); current.responseCode = e.responseCode;
    current.reason = current.stage === 'Authentication' ? 'Authentication rejected or unsupported' : current.stage + ' failed';
    current.detail = redact(e.message);
    current.authRejected = current.stage === 'Authentication' && (e.responseCode === 535 || e.responseCode === 534);
  } finally { if (transport && transport !== native && transport.close) transport.close(); env(appEnv); }
  const result = current; current = null; return result;
}
async function dispatch(req) {
  if (req.action === 'init') return init(req);
  if (req.action === 'test') return test(req);
  if (req.action === 'quit') { process.exit(0); }
  return { ok: false, stage: 'Protocol', reason: 'Unknown worker request' };
}
let queue = Promise.resolve();
require('readline').createInterface({ input: process.stdin }).on('line', line => {
  queue = queue.then(async () => {
    let answer;
    try { answer = await dispatch(JSON.parse(line)); }
    catch (_) { answer = { ok: false, stage: 'Application/Node', reason: 'Worker operation failed; raw exception suppressed to protect credentials.' }; }
    write(JSON.stringify(answer) + '\n');
  });
});
process.stdin.on('end', () => process.exit(0));
'@
$pythonSource = @'
"""Independent no-send SMTP validator. Credentials arrive over redirected stdin only."""
import json
import base64
import socket
import ssl
import smtplib
import sys


def run(p):
    r = dict(ok=False, stage="DNS", encrypted=False, authenticated=False)
    smtp = None
    try:
        socket.getaddrinfo(p['host'], p['port'], type=socket.SOCK_STREAM)
        r['stage'] = 'TCP/SMTP banner'
        context = ssl.create_default_context()
        if not p['validate']:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        if p['mode'] == 'implicit':
            r['stage'] = 'TLS negotiation/SMTP banner'
            smtp = smtplib.SMTP_SSL(p['host'], p['port'], timeout=p['timeout'], context=context, local_hostname=p['ehloName'])
            r['encrypted'] = True
        else:
            smtp = smtplib.SMTP(p['host'], p['port'], timeout=p['timeout'], local_hostname=p['ehloName'])
        r['stage'] = 'EHLO/HELO'
        smtp.ehlo_or_helo_if_needed()
        starttls = smtp.has_extn('starttls')
        r['starttls'] = starttls
        if p['mode'] == 'required' and not starttls:
            r.update(stage='STARTTLS', reason='STARTTLS not offered')
            return r
        if p['mode'] == 'required' or (p['mode'] == 'opportunistic' and starttls):
            r['stage'] = 'TLS negotiation'
            smtp.starttls(context=context)
            r['encrypted'] = True
            r['stage'] = 'EHLO/HELO'
            smtp.ehlo()
        if r['encrypted']:
            c = smtp.sock.getpeercert()
            r['certificate'] = dict(subject=c.get('subject'), issuer=c.get('issuer'), validFrom=c.get('notBefore'), validUntil=c.get('notAfter'),
                                    protocol=smtp.sock.version(), validation='PASS' if p['validate'] else 'DISABLED (diagnostic only)')
        if p.get('user'):
            r['stage'] = 'Authentication'
            # smtplib.login encodes SASL answers as ASCII. Encode non-ASCII credentials
            # explicitly for PLAIN/LOGIN, preserving the exact UTF-8 password bytes.
            if not (p['user'] + p['password']).isascii():
                mechanisms = smtp.esmtp_features.get('auth', '').upper().split()
                def b64(value):
                    return base64.b64encode(value.encode('utf-8')).decode('ascii')
                if 'PLAIN' in mechanisms:
                    code, response = smtp.docmd('AUTH', 'PLAIN '+b64('\0'+p['user']+'\0'+p['password']))
                    if code == 334:
                        code, response = smtp.docmd(b64('\0'+p['user']+'\0'+p['password']))
                elif 'LOGIN' in mechanisms:
                    code, response = smtp.docmd('AUTH', 'LOGIN')
                    if code == 334:
                        code, response = smtp.docmd(b64(p['user']))
                    if code == 334:
                        code, response = smtp.docmd(b64(p['password']))
                else:
                    raise smtplib.SMTPNotSupportedError('No supported UTF-8 credential mechanism')
                if code != 235:
                    raise smtplib.SMTPAuthenticationError(code,response)
            else:
                smtp.login(p['user'], p['password'])
            r['authenticated'] = True
        r.update(ok=True, stage='Complete', reason='Authentication succeeded' if r['authenticated'] else 'Connection verified; no credentials configured')
    except ssl.SSLCertVerificationError as e:
        r.update(stage='Certificate validation', reason='Certificate verification failed', verifyCode=e.verify_code)
    except ssl.SSLError:
        r.update(stage='TLS negotiation', reason='TLS protocol/cipher or handshake failure')
    except smtplib.SMTPAuthenticationError as e:
        r.update(stage='Authentication', reason='Authentication rejected', responseCode=e.smtp_code, authRejected=e.smtp_code in (534, 535))
    except smtplib.SMTPNotSupportedError:
        r.update(reason='Required SMTP feature/authentication mechanism not supported')
    except socket.gaierror:
        r.update(stage='DNS', reason='DNS resolution failed')
    except (socket.timeout, TimeoutError):
        r.update(reason='Connection or operation timed out')
    except ConnectionRefusedError:
        r.update(stage='TCP', reason='TCP connection refused')
    except Exception:
        # SMTP servers may echo credentials in errors; do not serialize raw responses.
        r.update(reason='Connection closed, SMTP rejection, or unsupported client setting')
    finally:
        if smtp:
            smtp.close()
    return r


if __name__ == '__main__':
    try:
        print(json.dumps(run(json.loads(sys.stdin.readline()))))
    except Exception:
        print(json.dumps(dict(ok=False, stage='Python', reason='Python worker input/runtime error')))
'@
$probeSource = @'
// Used by PowerShell 5.1 and 7. No global TLS callbacks or ServicePointManager changes.
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Collections.Generic;

public sealed class D4ASmtpResult {
    public bool ok, encrypted, authenticated, starttls, authAttempted;
    public string stage = "DNS", reason = "", protocol = "", auth = "", banner = "";
    public string subject = "", issuer = "", validFrom = "", validUntil = "";
    public string hostnameValidation = "not tested", chainValidation = "not tested";
    public string[] addresses = new string[0];
}

public static class D4ASmtpProbe {
    private static string Reply(Stream s, out int code) {
        var lines = new List<string>();
        code = 0;
        for (int n = 0; n < 80; n++) {
            var b = new StringBuilder();
            for (int i = 0; i < 4096; i++) {
                int c = s.ReadByte();
                if (c < 0) throw new IOException("SMTP connection closed");
                if (c == 10) break;
                if (c != 13) b.Append((char)c);
                if (i == 4095) throw new IOException("SMTP reply too long");
            }
            string line = b.ToString();
            if (line.Length < 3 || !Int32.TryParse(line.Substring(0, 3), out code))
                throw new IOException("Invalid SMTP reply");
            lines.Add(line.Length > 4 ? line.Substring(4) : "");
            if (line.Length < 4 || line[3] != '-') return String.Join("\n", lines.ToArray());
        }
        throw new IOException("Too many SMTP reply lines");
    }
    private static void Send(Stream s, string command) {
        byte[] data = Encoding.UTF8.GetBytes(command + "\r\n");
        s.Write(data, 0, data.Length); s.Flush();
        Array.Clear(data, 0, data.Length);
    }
    private static string Ehlo(Stream s, string name) {
        int code; Send(s, "EHLO " + name);
        string reply = Reply(s, out code);
        if (code == 500 || code == 502 || code == 504) {
            Send(s, "HELO " + name); Reply(s, out code);
            if (code == 250) return "";
        }
        if (code != 250) throw new InvalidOperationException("EHLO/HELO rejected (" + code + ")");
        return reply;
    }
    private static void Capabilities(D4ASmtpResult r, string reply) {
        r.starttls = false; r.auth = "";
        foreach (string line in reply.Split('\n')) {
            if (line.Trim().Equals("STARTTLS", StringComparison.OrdinalIgnoreCase)) r.starttls = true;
            if (line.StartsWith("AUTH ", StringComparison.OrdinalIgnoreCase) || line.StartsWith("AUTH=", StringComparison.OrdinalIgnoreCase))
                r.auth = line.Substring(5).Trim().ToUpperInvariant();
        }
    }
    private static SslStream Tls(Stream raw, string name, bool validate, int timeout, D4ASmtpResult r) {
        var ssl = new SslStream(raw, false, delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
            if (cert != null) {
                var c = new X509Certificate2(cert);
                r.subject = c.Subject; r.issuer = c.Issuer;
                r.validFrom = c.NotBefore.ToUniversalTime().ToString("o");
                r.validUntil = c.NotAfter.ToUniversalTime().ToString("o");
                r.hostnameValidation = (errors & SslPolicyErrors.RemoteCertificateNameMismatch) == 0 ? "PASS" : "FAIL: hostname mismatch";
                var statuses = new List<string>();
                if (chain != null) foreach (X509ChainStatus st in chain.ChainStatus) statuses.Add(st.Status.ToString());
                r.chainValidation = errors == SslPolicyErrors.None ? "PASS" : String.Join(", ", statuses.ToArray());
                if ((errors & SslPolicyErrors.RemoteCertificateNotAvailable) != 0) r.chainValidation = "certificate unavailable";
            }
            return !validate || errors == SslPolicyErrors.None;
        });
        ssl.ReadTimeout = timeout; ssl.WriteTimeout = timeout;
        // SslProtocols.None delegates protocol selection to Windows/.NET policy.
        var task = ssl.AuthenticateAsClientAsync(name, null, SslProtocols.None, true);
        if (!task.Wait(timeout)) { ssl.Dispose(); throw new TimeoutException("TLS handshake timeout"); }
        r.encrypted = true; r.protocol = ssl.SslProtocol.ToString();
        return ssl;
    }
    public static D4ASmtpResult Run(string host, int port, string mode, string user, string password,
                                    bool validate, bool authenticate, int timeout, string servername, string ehloName) {
        var r = new D4ASmtpResult(); TcpClient tcp = null; Stream stream = null;
        // A whole-operation deadline also bounds deliberately slow/multiline SMTP peers.
        var deadline = new System.Threading.Timer(delegate(object state) {
            try { if (tcp != null) tcp.Close(); } catch { }
        }, null, timeout, 100);
        try {
            var dns = Dns.GetHostAddressesAsync(host);
            if (!dns.Wait(timeout)) throw new TimeoutException("DNS timeout");
            var names = new List<string>(); foreach (IPAddress ip in dns.Result) names.Add(ip.ToString());
            r.addresses = names.ToArray();
            r.stage = "TCP";
            // Try the resolved addresses within one connection budget (including IPv6).
            var watch = System.Diagnostics.Stopwatch.StartNew();
            foreach (IPAddress ip in dns.Result) {
                int remaining = timeout - (int)watch.ElapsedMilliseconds;
                if (remaining <= 0) break;
                tcp = new TcpClient(ip.AddressFamily);
                try {
                    var connect = tcp.ConnectAsync(ip, port);
                    if (!connect.Wait(Math.Min(remaining, 4000))) { tcp.Close(); tcp = null; continue; }
                    if (tcp.Connected) break;
                } catch { tcp.Close(); tcp = null; }
            }
            if (tcp == null || !tcp.Connected) throw new IOException("TCP port unreachable or timed out");
            stream = tcp.GetStream(); stream.ReadTimeout = timeout; stream.WriteTimeout = timeout;
            if (mode == "implicit") { r.stage = "TLS negotiation"; stream = Tls(stream, servername, validate, timeout, r); }
            r.stage = "SMTP banner";
            int code; r.banner = Reply(stream, out code);
            if (code != 220) throw new InvalidOperationException("SMTP service unavailable (" + code + ")");
            r.stage = "EHLO/HELO"; Capabilities(r, Ehlo(stream, ehloName));
            if (mode == "required" || (mode == "opportunistic" && r.starttls)) {
                r.stage = "STARTTLS";
                if (!r.starttls) throw new InvalidOperationException("STARTTLS not offered");
                Send(stream, "STARTTLS"); Reply(stream, out code);
                if (code != 220) throw new InvalidOperationException("STARTTLS rejected (" + code + ")");
                r.stage = "TLS negotiation"; stream = Tls(stream, servername, validate, timeout, r);
                r.stage = "EHLO/HELO"; Capabilities(r, Ehlo(stream, ehloName));
                r.starttls = true;
            }
            if (authenticate && !String.IsNullOrEmpty(user)) {
                r.stage = "Authentication";
                if (Array.IndexOf(r.auth.Split(' '), "PLAIN") >= 0) {
                    r.authAttempted = true;
                    Send(stream, "AUTH PLAIN " + Convert.ToBase64String(Encoding.UTF8.GetBytes("\0" + user + "\0" + password)));
                    Reply(stream, out code);
                    if (code == 334) { Send(stream, Convert.ToBase64String(Encoding.UTF8.GetBytes("\0" + user + "\0" + password))); Reply(stream, out code); }
                } else if (Array.IndexOf(r.auth.Split(' '), "LOGIN") >= 0) {
                    r.authAttempted = true; Send(stream, "AUTH LOGIN"); Reply(stream, out code);
                    if (code == 334) { Send(stream, Convert.ToBase64String(Encoding.UTF8.GetBytes(user))); Reply(stream, out code); }
                    if (code == 334) { Send(stream, Convert.ToBase64String(Encoding.UTF8.GetBytes(password))); Reply(stream, out code); }
                } else throw new InvalidOperationException("Unsupported or unadvertised authentication mechanism (PowerShell supports PLAIN/LOGIN)");
                if (code != 235) throw new InvalidOperationException("Authentication rejected (" + code + ")");
                r.authenticated = true;
            }
            r.ok = true; r.stage = "Complete";
            r.reason = r.authenticated ? "Authentication succeeded" : "Connection verified; authentication not tested";
            try { Send(stream, "QUIT"); } catch { }
        } catch (Exception ex) {
            while (ex.InnerException != null) ex = ex.InnerException;
            if (ex is AuthenticationException) r.reason = "TLS handshake or certificate validation failed";
            else if (ex is System.ComponentModel.Win32Exception) r.reason = "Windows TLS/security provider failed (0x" + ((System.ComponentModel.Win32Exception)ex).NativeErrorCode.ToString("X8") + ")";
            else if (ex is TimeoutException) r.reason = ex.Message;
            else if (ex is InvalidOperationException) r.reason = ex.Message;
            else if (r.stage == "DNS") r.reason = "DNS resolution failed";
            else if (r.stage == "TCP") r.reason = "TCP port unreachable or timed out";
            else r.reason = "Connection closed, invalid response, or timeout at " + r.stage + " (" + ex.GetType().Name + ", 0x" + ex.HResult.ToString("X8") + ")";
        } finally { deadline.Dispose(); if (stream != null) stream.Dispose(); if (tcp != null) tcp.Close(); }
        return r;
    }
}
'@

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Protect-Text($Value) {
    $text = [string]$Value
    foreach ($secret in $script:SecretValues) { if ($secret) { $text = $text.Replace($secret, '[REDACTED]') } }
    return [regex]::Replace($text, '[\x00-\x08\x0b-\x1f\x7f]', '')
}
function Protect-Object($Value) {
    # Redact string values before JSON serialization. Replacing text in serialized
    # JSON would corrupt booleans/null for short passwords, or miss escaped quotes.
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Protect-Text $Value }
    if ($Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $clean = [ordered]@{}
        foreach ($key in $Value.Keys) { $clean[[string]$key] = Protect-Object $Value[$key] }
        return $clean
    }
    if ($Value -is [Collections.IEnumerable]) {
        $clean = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$clean.Add((Protect-Object $item)) }
        return ,$clean.ToArray()
    }
    $clean = [ordered]@{}
    foreach ($prop in $Value.PSObject.Properties) { $clean[$prop.Name] = Protect-Object $prop.Value }
    return $clean
}
function Say([string]$Kind, [string]$Text) {
    $color = switch ($Kind) { 'PASS' {'Green'} 'FAIL' {'Red'} 'SKIP' {'DarkYellow'} 'WARN' {'Yellow'} default {'Cyan'} }
    Write-Host ('[{0}] {1}' -f $Kind, (Protect-Text $Text)) -ForegroundColor $color
}
function Ask([string]$Prompt, [string]$Default = '') {
    if ($NonInteractive) { return $Default }
    $value = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}
function Resolve-Executable([string]$Explicit, [string[]]$Names) {
    if ($Explicit) {
        $p = $Explicit.Trim('"')
        if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
        Say SKIP 'The specified runtime executable does not exist.'; return $null
    }
    foreach ($name in $Names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source -notmatch '\\WindowsApps\\') { return $cmd.Source }
    }
    return $null
}
function New-Worker([string]$Executable, [string]$File, [string]$WorkingDirectory) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    # Only a generated helper path is passed on the command line. Never credentials.
    $start.Arguments = '"' + $File + '"'
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    if ($start.PSObject.Properties['StandardInputEncoding']) { $start.StandardInputEncoding = New-Object Text.UTF8Encoding($false) }
    $start.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $start
    [void]$p.Start()
    # Drain stderr without ever displaying or persisting untrusted dependency output.
    $p | Add-Member -NotePropertyName ErrorDrain -NotePropertyValue $p.StandardError.ReadToEndAsync()
    return $p
}
function Stop-Worker($Process) {
    if ($null -eq $Process) { return }
    try { if (-not $Process.HasExited) { $Process.Kill(); [void]$Process.WaitForExit(2000) } } catch { }
    $Process.Dispose()
}
function Invoke-Pipe($Process, $Request) {
    try {
        # .NET Framework's StreamWriter may otherwise use the current ANSI codepage.
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 15 -Compress) + "`n")
        $Process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
        $Process.StandardInput.BaseStream.Flush()
        [Array]::Clear($bytes,0,$bytes.Length)
        $read = $Process.StandardOutput.ReadLineAsync()
        if (-not $read.Wait($TimeoutSeconds * 1000)) {
            Stop-Worker $Process
            if ($Process -eq $script:Worker) { $script:Worker = $null; $script:NodeAvailable = $false }
            return @{ ok=$false; stage='External timeout'; reason='Test exceeded the diagnostic time limit; worker stopped. Native transport options were not changed.' }
        }
        if (-not $read.Result) { throw 'Empty private worker response' }
        return ($read.Result | ConvertFrom-Json)
    } catch {
        # Never include raw IPC / loader output in an error.
        return @{ ok=$false; stage='Runtime'; reason='Worker exited or returned an invalid response; raw output suppressed.' }
    }
}
function Convert-Fields($Object) {
    $h = @{}
    if ($Object -is [System.Collections.IDictionary]) { foreach ($key in $Object.Keys) { $h[$key] = $Object[$key] } }
    elseif ($Object) { foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}
function Get-Settings($Patch, $Environment) {
    $f = Convert-Fields $script:Config.fields
    foreach ($key in $Patch.Keys) { if ($null -eq $Patch[$key]) { $f.Remove($key) } else { $f[$key] = $Patch[$key] } }
    $secure = Get-Value $f 'secure' ($script:Config.port -eq 465)
    $mode = if ($secure) { 'implicit' } elseif (Get-Value $f 'ignoreTLS' $false) { 'none' } elseif (Get-Value $f 'requireTLS' $false) { 'required' } else { 'opportunistic' }
    $validate = (Get-Value $f 'tls.rejectUnauthorized' $true) -ne $false -and $Environment -ne '0'
    return @{ fields=$f; mode=$mode; validate=$validate; servername=(Get-Value $f 'tls.servername' $script:Config.host); ehloName=(Get-Value $f 'name' ([Net.Dns]::GetHostName())) }
}
function Record([string]$Name, [string]$Engine, $Result, $Patch = @{}, $Environment = $null) {
    # Explicit allowlist: this report object never contains credentials, complete options or app exports.
    $entry = [ordered]@{ name=$Name; engine=$Engine; ok=[bool](Get-Value $Result 'ok' $false); stage=(Get-Value $Result 'stage' 'Unknown');
        reason=(Protect-Text (Get-Value $Result 'reason' 'No result')); encrypted=[bool](Get-Value $Result 'encrypted' $false);
        authenticated=[bool](Get-Value $Result 'authenticated' $false); patch=$Patch; environment=$Environment }
    foreach ($key in @('detail','code','responseCode','certificate','subject','issuer','validFrom','validUntil','hostnameValidation','chainValidation','protocol','addresses','starttls','auth','authRejected')) {
        $v = Get-Value $Result $key
        if ($null -ne $v) { $entry[$key] = $v }
    }
    # Redact the whole allowlisted object, including certificate fields and error details.
    $safe = (Protect-Object $entry) | ConvertTo-Json -Depth 15 -Compress | ConvertFrom-Json
    [void]$script:Results.Add($safe)
    $status = if ($safe.ok) {'PASS'} elseif ($safe.stage -eq 'Skipped') {'SKIP'} else {'FAIL'}
    Say $status ($Name + ': ' + $safe.reason)
    if (Get-Value $Result 'authRejected' $false) { $script:AuthBlocked = $true }
    if ((Get-Value $Result 'reason' '') -match 'Authentication rejected \((534|535)\)') { $script:AuthBlocked = $true }
    return $safe
}
function Invoke-NodeTest([string]$Name, [string]$Kind, $Patch = @{}, $Environment = $null) {
    $script:TrialCount++
    Say INFO ('Testing ' + $Name + '...')
    if (-not $script:NodeAvailable) { return Record $Name 'Nodemailer' @{ok=$false; stage='Skipped'; reason='Node/Nodemailer worker unavailable'} $Patch $Environment }
    $request = @{action='test';kind=$Kind;patch=$Patch}
    if ($Kind -ne 'native') { $request.environment = $Environment }
    $result = Invoke-Pipe $script:Worker $request
    return Record $Name 'Nodemailer' $result $Patch $Environment
}
function Invoke-Candidate([string]$Name, $Patch, $Environment) {
    if ($script:NodeAvailable) { return Invoke-NodeTest $Name 'generic' $Patch $Environment }
    $script:TrialCount++
    return Invoke-Probe ($Name + ' (PowerShell approximation)') $Patch $Environment $true
}
function Invoke-Probe([string]$Name, $Patch, $Environment, [bool]$Authenticate, [string]$ModeOverride = '') {
    $s = Get-Settings $Patch $Environment
    if ($ModeOverride) { $s.mode = $ModeOverride }
    $result = [D4ASmtpProbe]::Run($script:Config.host, [int]$script:Config.port, $s.mode,
        $script:Config.user, $script:Config.password, $s.validate, $Authenticate, $TimeoutSeconds*1000, $s.servername, $s.ehloName)
    return Record $Name 'PowerShell/.NET' $result $Patch $Environment
}
function New-ManualConfig {
    if (-not $SmtpHost) { $script:SmtpHost = Ask 'SMTP hostname' }
    if (-not $SmtpHost -or $SmtpHost -match '[\s\r\n]') { throw 'A valid SMTP hostname is required.' }
    if (-not $NonInteractive) {
        $value = Ask ('SMTP port [{0}]' -f $Port) ([string]$Port)
        $n = 0
        if (-not [int]::TryParse($value,[ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw 'Port must be between 1 and 65535.' }
        $script:Port = $n
        $suggested = if ($Port -eq 465) {'implicit'} else {'required'}
        $script:TlsMode = (Ask "TLS mode: required, opportunistic, implicit, none [$suggested]" $suggested).ToLowerInvariant()
        if ($TlsMode -notin @('required','opportunistic','implicit','none')) { throw 'Invalid TLS mode.' }
    }
    $user = ''; $password = ''
    if ($Credential) { $user = $Credential.UserName; $password = $Credential.GetNetworkCredential().Password }
    elseif (-not $NonInteractive) {
        $user = Ask 'SMTP username (blank for no authentication)'
        if ($user) {
            $securePassword = Read-Host 'SMTP password' -AsSecureString
            $cred = New-Object PSCredential($user, $securePassword)
            $password = $cred.GetNetworkCredential().Password
        }
    }
    if (-not $From) { $script:From = Ask 'Sender/from address (optional until a message test)' }
    $opts = @{host=$SmtpHost;port=$Port;secure=($TlsMode -eq 'implicit'); requireTLS=($TlsMode -eq 'required'); ignoreTLS=($TlsMode -eq 'none')}
    if ($user) { $opts.auth = @{user=$user;pass=$password} }
    $f = @{secure=$opts.secure;requireTLS=$opts.requireTLS;ignoreTLS=$opts.ignoreTLS}
    return @{options=$opts;from=$From;host=$SmtpHost;port=$Port;user=$user;password=$password;authType='login';fields=$f;
        environment=$env:NODE_TLS_REJECT_UNAUTHORIZED;customTls=@();customOptions=@();extraCA=$false}
}
function Show-Certificate($Entry) {
    $c = Get-Value $Entry 'certificate'
    if ($c) { Write-Host (Protect-Text ($c | ConvertTo-Json -Depth 8)) }
    elseif (Get-Value $Entry 'subject') {
        foreach ($key in @('subject','issuer','validFrom','validUntil','hostnameValidation','chainValidation','protocol')) {
            Write-Host (Protect-Text ('  {0}: {1}' -f $key,(Get-Value $Entry $key)))
        }
    }
}
function Get-NextStep([string]$Stage) {
    switch -Regex ($Stage) {
        'DNS' { return 'Check this server DNS configuration and the SMTP hostname.' }
        '^TCP' { return 'Verify the listener, routing and firewall for this hostname and port from the application server.' }
        'Certificate' { return 'Correct the server certificate SAN, expiry and intermediate chain; configure the issuing CA in Node trust (for example NODE_EXTRA_CA_CERTS) and retest with validation enabled.' }
        'Authentication' { return 'Verify the account/password, allowed AUTH mechanisms, SMTP AUTH policy and account lockout status. Credential retries were limited.' }
        'STARTTLS' { return 'Verify STARTTLS support and the server TLS policy on this exact port.' }
        'TLS' { return 'Compare the server TLS protocol/ciphers with Node/OpenSSL and Windows policy; inspect certificates and any SMTP inspection device.' }
        'Application|Runtime|Configuration|Dependency' { return 'Use the installed D4A Node runtime, dependencies, environment and service account; check dbconfig.js loading and exports.' }
        'Relay|send' { return 'Verify sender/recipient and relay authorization with the mail administrator.' }
        default { return 'Check SMTP service logs, banner/EHLO replies, network inspection and the service-account environment. Increase -TimeoutSeconds if the server is slow.' }
    }
}

try {
    Write-Host 'D4A SMTP diagnostics - connection/authentication only; sending is optional.' -ForegroundColor Cyan
    if (-not $Manual -and -not $ConfigPath) {
        $ConfigPath = Ask 'Enter the full path to dbconfig.js, or press M for manual SMTP configuration'
        if ($ConfigPath -eq 'M') { $Manual = $true; $ConfigPath = '' }
    }
    if (-not $Manual) {
        if (-not $ConfigPath) { throw 'Provide -ConfigPath or choose manual configuration.' }
        $ConfigPath = $ConfigPath.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'The supplied dbconfig.js file does not exist.' }
        $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
        $ModuleDirectory = Split-Path -Parent $ConfigPath
    }
    if (-not $ModuleDirectory) { $ModuleDirectory = (Get-Location).Path }
    $ModuleDirectory = $ModuleDirectory.Trim('"')
    if (-not (Test-Path -LiteralPath $ModuleDirectory -PathType Container)) { throw 'The module/application directory does not exist.' }
    $node = Resolve-Executable $NodePath @('node.exe','node')
    if (-not $node) {
        foreach ($candidate in @((Join-Path $ModuleDirectory 'node.exe'), (Join-Path (Split-Path $ModuleDirectory -Parent) 'node.exe'))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $node = $candidate; break }
        }
    }
    $python = Resolve-Executable $PythonPath @('python.exe','python3.exe','python3','python','py.exe')
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('D4A-SmtpDiagnostic-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $utf8 = New-Object Text.UTF8Encoding($false)
    $nodeFile = Join-Path $tempRoot 'smtp-worker.js'; $pythonFile = Join-Path $tempRoot 'smtp-worker.py'
    [IO.File]::WriteAllText($nodeFile, $nodeSource, $utf8)
    [IO.File]::WriteAllText($pythonFile, $pythonSource, $utf8)
    if (-not ('D4ASmtpProbe' -as [type])) { Add-Type -TypeDefinition $probeSource -Language CSharp }
    $manualConfig = $null
    if ($Manual) { $manualConfig = New-ManualConfig; $script:Config = $manualConfig }
    if ($node) {
        $script:Worker = New-Worker $node $nodeFile $ModuleDirectory
        $request = if ($Manual) { @{action='init';options=$manualConfig.options;from=$From;moduleDir=$ModuleDirectory} } else { @{action='init';configPath=$ConfigPath} }
        $init = Invoke-Pipe $script:Worker $request
        if (Get-Value $init 'ok' $false) { $script:Config = $init; $script:NodeAvailable = $true }
        else { Say SKIP (Get-Value $init 'reason' 'Node initialization failed') }
    } else { Say SKIP 'Node.js was not found. Supply -NodePath for the installed application runtime.' }
    if (-not $script:Config) {
        Say WARN 'The native dbconfig.js test is unavailable. Its values will not be guessed or extracted with regex.'
        if ($NonInteractive) { throw 'Cannot load the native configuration without its working Node/Nodemailer dependencies.' }
        Say INFO 'Continuing with a separately labelled manual configuration.'
        $Manual = $true; $manualConfig = New-ManualConfig; $script:Config = $manualConfig
    }
    if ($script:Config.password) {
        $script:SecretValues.Add([string]$script:Config.password)
        $script:SecretValues.Add([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$script:Config.password)))
        $script:SecretValues.Add([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([char]0 + $script:Config.user + [char]0 + $script:Config.password)))
    }
    Say INFO ('SMTP server: {0}:{1}' -f $script:Config.host,$script:Config.port)
    Say INFO ('PowerShell {0}; Node {1}; Python {2}' -f $PSVersionTable.PSVersion, $(if ($node) {$node} else {'unavailable'}), $(if ($python) {$python} else {'unavailable'}))
    Say INFO 'No SMTP passwords, complete application exports, or raw protocol logs will be displayed.'
    $appEnv = $script:Config.environment
    Write-Host ('Native TLS settings: ' + ((Convert-Fields $script:Config.fields) | ConvertTo-Json -Compress))
    Write-Host ('NODE_TLS_REJECT_UNAUTHORIZED (child process): ' + $(if ($null -eq $appEnv) {'unset'} else {$appEnv}))
    if ($script:NodeAvailable) { $script:Native = Invoke-NodeTest 'Native / Current Configuration' 'native' @{} $appEnv }
    else { $script:Native = Invoke-Probe 'Manual / Current Configuration (PowerShell)' @{} $appEnv $true }
    if (-not $script:Native.ok) {
        Say INFO ('Native failure stage: ' + $script:Native.stage)
        $detail = Get-Value $script:Native 'detail'
        if ($detail) { Write-Host ('Native error: ' + (Protect-Text $detail)) }
    }
    if ($script:Native.stage -eq 'External timeout' -and $node) {
        # A server waiting for an implicit TLS ClientHello never emits a plaintext banner.
        # The baseline deadline kills that worker; reload once so a different protocol can be tested.
        Say INFO 'Reloading the isolated Node worker after the native timeout for protocol diagnostics.'
        $script:Worker = New-Worker $node $nodeFile $ModuleDirectory
        $reinit = Invoke-Pipe $script:Worker $request
        $script:NodeAvailable = [bool](Get-Value $reinit 'ok' $false)
    }
    $winner = $null; $diagnosticOnly = $null; $confirmed = $false
    $settings = Get-Settings @{} $appEnv
    if ($script:Native.ok) { $winner = $script:Native; $confirmed = $true }
    # Probe after the native test. No AUTH, MAIL FROM, RCPT TO or DATA in capability discovery.
    $discovery = $null
    if (-not $script:Native.ok -and $script:Native.stage -notmatch '^DNS|^TCP$|Authentication|Application|Configuration|Runtime') {
        Say INFO 'Discovering SMTP capabilities without authentication...'
        $discovery = Invoke-Probe 'SMTP capability discovery' @{} $appEnv $false 'none'
        if ($discovery.ok) { Say INFO ('STARTTLS advertised: {0}; AUTH: {1}' -f (Get-Value $discovery 'starttls' $false),(Get-Value $discovery 'auth' 'none')) }
    }
    if (-not $winner -and -not $script:AuthBlocked -and $script:Native.stage -notmatch '^DNS|^TCP$|Authentication|Application|Configuration|Runtime') {
        $candidates = New-Object System.Collections.ArrayList
        # First fix only protocol-mode conflicts proven by the server's response.
        if ($discovery -and $discovery.ok -and (Get-Value $discovery 'starttls' $false)) {
            $patch = @{}
            if ($settings.mode -eq 'implicit') { $patch.secure = $false }
            if (Get-Value $settings.fields 'ignoreTLS' $false) { $patch.ignoreTLS = $false }
            if ($patch.Count) { [void]$candidates.Add(@{name='STARTTLS transport correction';patch=$patch;environment=$appEnv}) }
            # Do not rerun an identical opportunistic configuration after an unrelated TLS failure.
            if ($script:Native.stage -eq 'STARTTLS' -and -not $patch.Count) {
                [void]$candidates.Add(@{name='Require STARTTLS';patch=@{requireTLS=$true;ignoreTLS=$false};environment=$appEnv})
            }
        } elseif ($discovery -and -not $discovery.ok -and $discovery.stage -eq 'SMTP banner' -and $settings.mode -ne 'implicit') {
            # No plaintext greeting: one implicit-TLS probe is relevant on any user-selected port.
            [void]$candidates.Add(@{name='Implicit TLS transport';patch=@{secure=$true};environment=$appEnv})
        }
        # Certificate bypass is a single labelled diagnostic, never a permanent recommendation.
        $basis = @{}
        if ($candidates.Count) { foreach ($k in $candidates[0].patch.Keys) { $basis[$k] = $candidates[0].patch[$k] } }
        foreach ($candidate in $candidates) {
            if ($script:AuthBlocked) { break }
            $trial = Invoke-Candidate $candidate.name $candidate.patch $candidate.environment
            if ($trial.ok) { $winner = $trial; break }
        }
        $last = if ($script:Results.Count) {$script:Results[$script:Results.Count-1]} else {$script:Native}
        $psCertError = ($script:Native.stage -match 'TLS' -and ((Get-Value $script:Native 'chainValidation' 'not tested') -notin @('not tested','PASS') -or (Get-Value $script:Native 'hostnameValidation' '') -like 'FAIL*'))
        if (-not $winner -and -not $script:AuthBlocked -and ($script:Native.stage -match 'Certificate' -or $last.stage -match 'Certificate' -or $psCertError)) {
            $unsafePatch = @{}; foreach ($k in $basis.Keys) {$unsafePatch[$k]=$basis[$k]}
            $unsafePatch['tls.rejectUnauthorized'] = $false
            Say WARN 'One certificate-validation bypass will be tested in the child process for diagnosis only.'
            $trial = Invoke-Candidate 'Certificate bypass (DIAGNOSTIC ONLY)' $unsafePatch $appEnv
            if ($trial.ok) { $diagnosticOnly = $trial }
        }
        # Remove one explicit protocol/cipher restriction at a time; never lower TLS security levels.
        if (-not $winner -and -not $diagnosticOnly -and -not $script:AuthBlocked -and $script:NodeAvailable -and $script:Native.stage -match 'TLS|STARTTLS') {
            foreach ($key in @('tls.ciphers','tls.secureProtocol','tls.minVersion','tls.maxVersion')) {
                if ($settings.fields.ContainsKey($key) -and $script:TrialCount -lt 8) {
                    $patch = @{}; foreach ($k in $basis.Keys) { $patch[$k]=$basis[$k] }; $patch[$key]=$null
                    $trial = Invoke-NodeTest ('Use runtime TLS default instead of ' + $key) 'generic' $patch $appEnv
                    if ($trial.ok) { $winner=$trial;break }
                    if ($script:AuthBlocked -or -not $script:NodeAvailable) { break }
                }
            }
        }
    }
    # An unsafe native success is reported accurately, then checked with secure validation.
    if ($winner -and -not $settings.validate -and -not $script:AuthBlocked) {
        $patch = Convert-Fields $winner.patch
        $patch['tls.rejectUnauthorized'] = $true
        $trial = Invoke-Candidate 'Certificate validation enabled; global bypass removed' $patch $null
        if ($trial.ok) { $winner=$trial; $confirmed=$false }
        else { $diagnosticOnly=$winner; $winner=$null; $confirmed=$false }
    }
    # Secure winner must be observed to encrypt, not merely have optimistic flags.
    if ($winner -and -not $winner.encrypted) { $diagnosticOnly=$winner; $winner=$null; $confirmed=$false }
    if ($winner -and $winner.name -ne $script:Native.name -and -not $script:AuthBlocked) {
        $check = Invoke-Candidate 'Confirm successful configuration' (Convert-Fields $winner.patch) $winner.environment
        $confirmed = $check.ok
        if (-not $confirmed) { Say WARN 'The alternative did not pass confirmation; no proven fix will be claimed.' }
    }
    $selected = if ($winner) {$winner} else {$script:Native}
    $selectedPatch = Convert-Fields $selected.patch
    $selectedSettings = Get-Settings $selectedPatch $selected.environment
    $psValidation = $null; $pythonValidation = $null; $genericValidation = $null
    $crossLimits = $false
    if ($script:AuthBlocked) { Say SKIP 'Further credential attempts stopped after an explicit authentication rejection.' }
    else {
        if ($script:NodeAvailable -and $script:Native.ok -and $selected.name -eq $script:Native.name) {
            $genericValidation = Invoke-NodeTest 'Generic Nodemailer with exported options' 'generic' @{} $appEnv
        }
        $crossLimits = @($script:Config.customTls).Count -gt 0 -or @($script:Config.customOptions).Count -gt 0 -or $script:Config.extraCA
        if ($crossLimits) { Say WARN 'Independent clients use OS/Python TLS trust and cannot reproduce every custom Node option. Their results are corroboration, not exact application equivalence.' }
        if ($script:AuthBlocked) {
            Say SKIP 'Independent authentication skipped after the generic Nodemailer credential rejection.'
        } elseif ($script:Config.authType -ne 'login' -or (Get-Value $selectedSettings.fields 'authMethod' '') -notin @('','PLAIN','LOGIN')) {
            Say SKIP 'Independent authentication is unavailable for the configured OAuth/custom mechanism; testing connectivity only in PowerShell.'
            $psValidation = Invoke-Probe 'PowerShell independent connectivity' $selectedPatch $selected.environment $false
        } else {
            $psValidation = Invoke-Probe 'PowerShell independent validation' $selectedPatch $selected.environment $true
            if ($python -and -not $script:AuthBlocked -and $selectedSettings.servername -eq $script:Config.host) {
                $p = $null
                try {
                    $p = New-Worker $python $pythonFile $ModuleDirectory
                    $result = Invoke-Pipe $p @{host=$script:Config.host;port=$script:Config.port;user=$script:Config.user;password=$script:Config.password;
                        mode=$selectedSettings.mode;validate=$selectedSettings.validate;timeout=$TimeoutSeconds;ehloName=$selectedSettings.ehloName}
                    $pythonValidation = Record 'Python independent validation' 'Python' $result $selectedPatch $selected.environment
                } finally { Stop-Worker $p }
            } elseif (-not $python) { Say SKIP 'Python validation - Python is not installed or was not found. Use -PythonPath if needed.' }
            elseif ($script:AuthBlocked) { Say SKIP 'Python authentication skipped after a credential rejection.' }
            else { Say SKIP 'Python standard smtplib cannot reproduce the custom TLS servername; Nodemailer remains authoritative.' }
        }
    }
    if ($script:Native.ok -and $winner -and $psValidation -and $psValidation.ok -and -not $psValidation.encrypted) { Say WARN 'The successful independent connection did not negotiate TLS; server behavior may vary between sessions.' }
    Write-Host "`nSMTP DIAGNOSTIC SUMMARY" -ForegroundColor Cyan
    Write-Host ('Server: {0}:{1}' -f $script:Config.host,$script:Config.port)
    Write-Host ('Native configuration: ' + $(if ($script:Native.ok) {'PASS'} else {'FAILED'}))
    if (-not $script:Native.ok) {
        Write-Host ('Failure stage: ' + $script:Native.stage)
        Write-Host ('Native error: ' + (Protect-Text (Get-Value $script:Native 'detail' $script:Native.reason)))
    }
    $changes = New-Object System.Collections.Generic.List[string]
    $recommendation = ''
    if ($winner -and $confirmed) {
        Write-Host 'Successful validated/encrypted configuration found: YES'
        $nativeFields = Convert-Fields $script:Config.fields
        $patch = Convert-Fields $winner.patch
        foreach ($key in ($patch.Keys | Sort-Object)) {
            $v = $patch[$key]; $old = Get-Value $nativeFields $key
            if ($null -eq $v -and $nativeFields.ContainsKey($key)) { $changes.Add("REMOVE $key") }
            elseif (-not $nativeFields.ContainsKey($key)) { $changes.Add(('ADD {0}: {1}' -f $key,($v | ConvertTo-Json -Compress))) }
            elseif ($v -ne $old) { $changes.Add(('CHANGE {0}: {1} -> {2}' -f $key,($old | ConvertTo-Json -Compress),($v | ConvertTo-Json -Compress))) }
        }
        if ($winner.environment -ne $appEnv) { $changes.Add('REMOVE global NODE_TLS_REJECT_UNAUTHORIZED bypass; keep certificate validation enabled') }
        if ($changes.Count -eq 0) { $recommendation='No SMTP configuration changes are recommended.'; Write-Host $recommendation }
        else {
            $recommendation='Apply the confirmed minimal settings changes below in the application configuration.'
            Write-Host $recommendation
            foreach ($change in $changes) { Write-Host (Protect-Text $change) }
            Write-Host 'KEEP: certificate validation enabled.'
            Write-Host 'Nodemailer options to add/change (remove the REMOVE entries separately):'
            $snippet = @{}; $tlsOptions=@{}
            foreach ($key in $patch.Keys) { if ($null -ne $patch[$key]) { if ($key.StartsWith('tls.')) {$tlsOptions[$key.Substring(4)]=$patch[$key]} else {$snippet[$key]=$patch[$key]} } }
            if ($tlsOptions.Count) {$snippet.tls=$tlsOptions}
            Write-Host ($snippet | ConvertTo-Json -Depth 5)
            Write-Host 'Reason: this configuration negotiated encrypted SMTP and passed the native-credential verification and confirmation tests.'
        }
        if (-not $script:NodeAvailable) { Say WARN 'This is an independent PowerShell result. The proposed Nodemailer settings and the actual application still require validation with Node/Nodemailer.' }
    } elseif ($diagnosticOnly) {
        $recommendation = if ($diagnosticOnly.encrypted) {
            'Authentication/connectivity succeeds only with certificate validation bypassed in the successful test. Correct the certificate, trust chain or hostname; do not retain rejectUnauthorized=false or NODE_TLS_REJECT_UNAUTHORIZED=0.'
        } else { 'The successful connection was unencrypted. This is a diagnostic finding, not a recommended permanent configuration. Enable TLS on the SMTP service or obtain its approved TLS endpoint.' }
        Write-Host 'Secure recommended configuration found: NO'
        Say WARN $recommendation
    } else {
        $recommendation = 'No confirmed SMTP configuration change tested resolves the problem. ' + (Get-NextStep $script:Native.stage)
        Write-Host 'Successful confirmed configuration found: NO'
        Write-Host $recommendation
    }
    Write-Host 'Validation results:'
    foreach ($entry in $script:Results) { Write-Host ('  {0}: {1} ({2})' -f $entry.name,$(if ($entry.ok) {'PASS'} else {$entry.stage}),$entry.engine) }
    if (-not $pythonValidation) { Write-Host '  Python validation: SKIPPED (see reason above).' }
    if (-not $script:NodeAvailable) { Write-Host '  Node/Nodemailer validation: UNAVAILABLE; application equivalence is unverified.' }
    $confidence = if ($winner -and $confirmed -and $script:NodeAvailable -and $psValidation -and $psValidation.ok -and $pythonValidation -and $pythonValidation.ok -and -not $crossLimits) {'HIGH'} elseif ($winner -and $confirmed -and $script:NodeAvailable) {'MEDIUM'} else {'LIMITED'}
    Write-Host ('Confidence: ' + $confidence)
    if (-not $script:Config.user) { Say INFO 'No authentication credentials were configured; PASS proves connection/TLS only.' }
    Write-Host 'Certificate observations (each engine uses its own trust store):'
    foreach ($entry in $script:Results) {
        if ((Get-Value $entry 'certificate') -or (Get-Value $entry 'subject')) { Write-Host ('  ' + $entry.name); Show-Certificate $entry }
    }
    if ($genericValidation -and -not $genericValidation.ok -and $script:Native.ok) { Say WARN 'The actual transporter succeeds but its recreated options fail. Investigate transporter customizations and application behavior.' }
    Say INFO 'Connection/AUTH success does not prove sender permission, relay permission or mailbox delivery.'
    # Sending is a separate opt-in and uses only a confirmed secure winner.
    if (-not $NoSendPrompt -and -not $NonInteractive -and $winner -and $confirmed -and $script:NodeAvailable -and -not $script:AuthBlocked) {
        if ((Ask 'Would you like to send an actual test email? [Y/N]' 'N') -eq 'Y') {
            $recipient = Ask 'Test recipient address'
            $sender = $script:Config.from
            if (-not $sender) { $sender = Ask 'Sender/from address' }
            if ($recipient -and $sender -and $recipient -notmatch '[\r\n]' -and $sender -notmatch '[\r\n]') {
                $result = Invoke-Pipe $script:Worker @{action='test';kind=$(if($winner.name -eq $script:Native.name){'native'}else{'generic'});patch=(Convert-Fields $winner.patch);environment=$winner.environment;send=$true;to=$recipient;from=$sender}
                $null = Record 'Operator-requested message' 'Nodemailer' $result
            } else { Say SKIP 'Message test requires valid sender and recipient addresses.' }
        }
    }
    if ($ReportPath) {
        $report = @{ server=$script:Config.host;port=$script:Config.port;timestamp=[DateTime]::UtcNow.ToString('o');nativePassed=$script:Native.ok;
            recommendation=$recommendation;changes=@($changes.ToArray());confidence=$confidence;results=@($script:Results.ToArray()) }
        $json = (Protect-Object $report) | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),$json,$utf8)
        Say INFO 'Credential-free diagnostic report saved.'
    }
} catch {
    # Avoid accidental credential leakage from PowerShell exception rendering.
    Say FAIL 'The diagnostic could not complete. Check the paths, runtime dependencies and input values.'
    if ($_.Exception.Message -match '^(Provide |A valid |Port must |Invalid TLS |The supplied |The module/|Cannot load)') { Say INFO $_.Exception.Message }
    else { Say INFO ('Failure location: script line {0}; {1}. Raw exception content suppressed.' -f $_.InvocationInfo.ScriptLineNumber,$_.Exception.GetType().Name) }
} finally {
    Stop-Worker $script:Worker
    $script:Worker=$null
    if ($script:Config) { if ($script:Config -is [Collections.IDictionary]) {$script:Config.password=''} elseif ($script:Config.PSObject.Properties['password']) {$script:Config.password=''} }
    $Credential=$null; $manualConfig=$null; $init=$null; $request=$null
    $script:SecretValues.Clear()
    if ($tempRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
        if ([IO.Path]::GetDirectoryName($resolvedTemp).TrimEnd('\','/') -eq $expectedParent -and [IO.Path]::GetFileName($resolvedTemp) -match '^D4A-SmtpDiagnostic-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
