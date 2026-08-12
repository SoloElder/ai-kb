const express = require('express');
const path = require('path');
const fs = require('fs');
const app = express();

app.use(express.json({ limit: '5mb' }));
app.use(express.static(path.join(__dirname, 'public')));

const DB_FILE = path.join(process.env.DATA_DIR || __dirname, 'data.json');

function loadDB() {
  try { return JSON.parse(fs.readFileSync(DB_FILE, 'utf8')); } catch(e) { return {}; }
}
function saveDB(db) {
  fs.writeFileSync(DB_FILE, JSON.stringify(db, null, 2), 'utf8');
}

function initDB() {
  if (!fs.existsSync(DB_FILE)) {
    saveDB({
      users: { root: { password: 'admin123', role: 'admin', created: Date.now() } },
      kb: {},      // { username: [ {id, category, title, content, ...} ] }
      chat: {},    // { username: [ {role, content} ] }
      config: {},  // { username: { "modelId": {endpoint, apiKey} } }
      logs: []     // [ {time, user, msg} ]
    });
  }
}

function addLog(user, msg) {
  var db = loadDB();
  db.logs.push({ time: new Date().toISOString(), user: user, msg: msg });
  if (db.logs.length > 1000) db.logs = db.logs.slice(-1000);
  saveDB(db);
}

// ====== Auth middleware ======
function auth(req, res, next) {
  var uname = req.headers['x-username'];
  var pwd = req.headers['x-password'];
  if (!uname || !pwd) return res.status(401).json({ error: '未登录' });
  var db = loadDB();
  var user = db.users[uname];
  if (!user || user.password !== pwd) return res.status(401).json({ error: '用户名或密码错误' });
  req.username = uname;
  req.role = user.role;
  next();
}

function adminOnly(req, res, next) {
  if (req.role !== 'admin') return res.status(403).json({ error: '需要管理员权限' });
  next();
}

// ====== Auth API ======
app.post('/api/login', function(req, res) {
  var db = loadDB();
  var user = db.users[req.body.username];
  if (!user || user.password !== req.body.password) return res.status(401).json({ error: '用户名或密码错误' });
  addLog(req.body.username, '登录');
  res.json({ username: req.body.username, role: user.role });
});

// ====== User management (admin) ======
app.get('/api/users', auth, adminOnly, function(req, res) {
  var db = loadDB();
  var users = {};
  Object.keys(db.users).forEach(function(k) {
    users[k] = { password: db.users[k].password, role: db.users[k].role, created: db.users[k].created || 0 };
  });
  // 附上各用户的知识库和对话数量
  Object.keys(users).forEach(function(k) {
    users[k].kbCount = (db.kb[k] || []).length;
    users[k].chatCount = (db.chat[k] || []).length;
  });
  res.json(users);
});

app.post('/api/users', auth, adminOnly, function(req, res) {
  var uname = (req.body.username || '').trim();
  var pwd = (req.body.password || '').trim();
  if (!uname || !pwd) return res.status(400).json({ error: '用户名和密码不能为空' });
  if (uname === 'root') return res.status(400).json({ error: '不能覆盖 root' });
  var db = loadDB();
  if (db.users[uname]) return res.status(400).json({ error: '用户已存在' });
  db.users[uname] = { password: pwd, role: 'user', created: Date.now() };
  saveDB(db);
  addLog(req.username, '创建用户: ' + uname);
  res.json({ ok: true });
});

app.delete('/api/users/:username', auth, adminOnly, function(req, res) {
  var uname = req.params.username;
  if (uname === 'root') return res.status(400).json({ error: '不能删除 root' });
  var db = loadDB();
  delete db.users[uname];
  delete db.kb[uname];
  delete db.chat[uname];
  delete db.config[uname];
  saveDB(db);
  addLog(req.username, '删除用户: ' + uname);
  res.json({ ok: true });
});

// ====== Change password ======
app.put('/api/password', auth, function(req, res) {
  var oldPwd = req.body.oldPassword || '';
  var newPwd = req.body.newPassword || '';
  if (!newPwd) return res.status(400).json({ error: '新密码不能为空' });
  var db = loadDB();
  if (db.users[req.username].password !== oldPwd) return res.status(400).json({ error: '旧密码错误' });
  db.users[req.username].password = newPwd;
  saveDB(db);
  addLog(req.username, '修改密码');
  res.json({ ok: true });
});

// ====== Knowledge Base ======
app.get('/api/kb', auth, function(req, res) {
  var db = loadDB();
  res.json(db.kb[req.username] || []);
});

app.post('/api/kb', auth, function(req, res) {
  var db = loadDB();
  if (!db.kb[req.username]) db.kb[req.username] = [];
  var entry = {
    id: 'kb_' + Date.now(),
    category: req.body.category || '',
    title: req.body.title || '',
    content: req.body.content || '',
    created: Date.now(), ts: Date.now()
  };
  db.kb[req.username].push(entry);
  saveDB(db);
  addLog(req.username, '添加知识条目: ' + entry.title);
  res.json(entry);
});

app.put('/api/kb/:id', auth, function(req, res) {
  var db = loadDB();
  var entries = db.kb[req.username] || [];
  var idx = entries.findIndex(function(e) { return e.id === req.params.id; });
  if (idx === -1) return res.status(404).json({ error: '条目不存在' });
  entries[idx].category = req.body.category || entries[idx].category;
  entries[idx].title = req.body.title || entries[idx].title;
  entries[idx].content = req.body.content || entries[idx].content;
  entries[idx].ts = Date.now();
  saveDB(db);
  addLog(req.username, '编辑知识条目: ' + entries[idx].title);
  res.json(entries[idx]);
});

app.delete('/api/kb/:id', auth, function(req, res) {
  var db = loadDB();
  db.kb[req.username] = (db.kb[req.username] || []).filter(function(e) { return e.id !== req.params.id; });
  saveDB(db);
  addLog(req.username, '删除知识条目');
  res.json({ ok: true });
});

// ====== Admin view user KB ======
app.get('/api/admin/kb/:username', auth, adminOnly, function(req, res) {
  var db = loadDB();
  var logs = (db.logs || []).filter(function(l) { return l.user === req.params.username; }).slice(-30);
  res.json({ kb: db.kb[req.params.username] || [], logs: logs });
});

// ====== Chat History ======
app.get('/api/chat', auth, function(req, res) {
  var db = loadDB();
  res.json(db.chat[req.username] || []);
});

app.post('/api/chat', auth, function(req, res) {
  var db = loadDB();
  if (!db.chat[req.username]) db.chat[req.username] = [];
  var msgs = req.body.messages || [];
  msgs.forEach(function(m) { db.chat[req.username].push(m); });
  if (db.chat[req.username].length > 200) db.chat[req.username] = db.chat[req.username].slice(-200);
  saveDB(db);
  res.json({ ok: true });
});

app.delete('/api/chat', auth, function(req, res) {
  var db = loadDB();
  db.chat[req.username] = [];
  saveDB(db);
  res.json({ ok: true });
});

// ====== Model Config ======
app.get('/api/config', auth, function(req, res) {
  var db = loadDB();
  res.json(db.config[req.username] || {});
});

app.put('/api/config', auth, function(req, res) {
  var db = loadDB();
  db.config[req.username] = req.body;
  saveDB(db);
  addLog(req.username, '更新API配置');
  res.json({ ok: true });
});

// ====== Logs (admin) ======
app.get('/api/logs', auth, adminOnly, function(req, res) {
  var db = loadDB();
  var logs = (db.logs || []).slice(-200);
  res.json(logs);
});

// ====== Export/Import users ======
app.get('/api/export-users', auth, adminOnly, function(req, res) {
  var db = loadDB();
  res.json(db.users);
});

app.post('/api/import-users', auth, adminOnly, function(req, res) {
  var db = loadDB();
  var imported = req.body;
  var merged = 0;
  Object.keys(imported).forEach(function(k) {
    if (!db.users[k]) { db.users[k] = imported[k]; merged++; }
  });
  saveDB(db);
  addLog(req.username, '导入用户库: ' + merged + ' 个');
  res.json({ merged: merged });
});

// ====== SPA fallback ======
app.use(function(req, res, next) {
  if (req.method === 'GET' && !req.path.startsWith('/api/')) {
    return res.sendFile(path.join(__dirname, 'public', 'index.html'));
  }
  next();
});

initDB();

var PORT = process.env.PORT || 3456;
app.listen(PORT, '0.0.0.0', function() {
  console.log('AI知识库服务已启动: http://localhost:' + PORT);
  console.log('管理员: root / admin123');
  console.log('按 Ctrl+C 停止服务');
});
