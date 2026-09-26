#!/usr/bin/env node
// Минимальный приёмник SMTP для стенда: принимает письмо и печатает его заголовки.
import { createServer } from 'node:net';
import { writeFileSync, mkdirSync } from 'node:fs';

const PORT = Number(process.env.SMTP_PORT || process.env.PORT || 1025);
// Письма кладём рядом с данными стенда, а не в текущий каталог.
const MAIL_DIR = process.env.STAND_HOME ? `${process.env.STAND_HOME}/mail` : 'mail';
mkdirSync(MAIL_DIR, { recursive: true });
let count = 0;

createServer((socket) => {
  let data = false;
  let buffer = '';
  socket.write('220 timetrack-stand ESMTP\r\n');
  socket.on('data', (chunk) => {
    const text = chunk.toString('utf8');
    if (data) {
      buffer += text;
      if (buffer.includes('\r\n.\r\n')) {
        data = false;
        const body = buffer.slice(0, buffer.indexOf('\r\n.\r\n'));
        const header = (name) => (new RegExp('^' + name + ': (.*)$', 'im').exec(body) || [, ''])[1].trim();
        count += 1;
        const file = `${MAIL_DIR}/${String(count).padStart(2, '0')}.eml`;
        writeFileSync(file, body);
        console.log(`письмо ${count}: «${header('Subject').slice(0, 80)}» → ${header('To')} (${body.length} байт, ${file})`);
        buffer = '';
        socket.write('250 OK\r\n');
      }
      return;
    }
    for (const line of text.split('\r\n').filter(Boolean)) {
      const cmd = line.slice(0, 4).toUpperCase();
      if (cmd.startsWith('EHLO') || cmd.startsWith('HELO')) socket.write('250-timetrack-stand\r\n250 AUTH PLAIN LOGIN\r\n');
      else if (cmd.startsWith('AUTH')) socket.write('235 Authentication succeeded\r\n');
      else if (cmd.startsWith('MAIL') || cmd.startsWith('RCPT')) socket.write('250 OK\r\n');
      else if (cmd.startsWith('DATA')) { data = true; socket.write('354 End data with <CR><LF>.<CR><LF>\r\n'); }
      else if (cmd.startsWith('QUIT')) { socket.write('221 Bye\r\n'); socket.end(); }
      else if (cmd.startsWith('RSET') || cmd.startsWith('NOOP')) socket.write('250 OK\r\n');
      else socket.write('250 OK\r\n');
    }
  });
  socket.on('error', () => {});
}).listen(PORT, () => console.log(`приёмник SMTP: localhost:${PORT}`));
