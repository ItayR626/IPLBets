const path = require("path");
const express = require("express");
const bodyParser = require("body-parser");
const cors = require("cors");
const session = require("express-session");
const MySQLStore = require("express-mysql-session")(session);
const doQuery = require("./database/query");
const app = express();
const port = process.env.PORT || 3000;
const crypto = require("crypto");
const { isLoggedIn } = require("./middleware/auth");


// Session store options
const options = {
  host: "localhost",
  user: "root",
  password: "",
  database: "project",
};

// Session store
const sessionStore = new MySQLStore(options);

function generateSecretKey() {
  return crypto.randomBytes(64).toString("hex");
}

const secretKey = generateSecretKey();

console.log("Secret Key:", secretKey);
// Session middleware configuration
app.use(
  session({
    key: "user_sid",
    secret: secretKey,
    store: sessionStore,
    resave: false,
    saveUninitialized: false,
    cookie: {
      maxAge: 24 * 60 * 60 * 1000, // 24 hours
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "lax",
    },
  })
);

app.use(express.static(path.join(__dirname, "front-end")));
app.use(bodyParser.json());
app.use(
  cors({
    origin: "http://localhost:3001",
    credentials: true,
  })
);



// Middleware to log requests
app.use((req, res, next) => {
  console.log(req.url);
  next();
});

// Error handling for 404
app.use((req, res, next) => {
  res.status(404).json({ message: "Route not found" });
});
app.listen(port, () => {
  console.log(`Server running on http://localhost:${port}`);
});
