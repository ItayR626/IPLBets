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

// Routes
const loginRoute = require("./routes/loginRoute");
const noticesRoute = require("./routes/noticeRoute");
const documentsRoute = require("./routes/documentsRoute");
const usersRoute = require("./routes/usersRoute");
const suppliersRoute = require("./routes/supplierRoute");
const productsRoute = require("./routes/productsRoute");
const ordersRoute = require("./routes/ordersRoutes");
const userProductsRequests = require("./routes/productsRequestRoutes");
const getRequests = require("./routes/getRequestsRoutes");
const emailRoute = require("./routes/emailRoute");
const constraintsRoute = require("./routes/constraintsRoute");
const meetingsRoute = require("./routes/meetingsRoute");
const customerMeetingAdminRoutes = require("./routes/customerMeetingAdminRoute");
const customerMeetingUserRoutes = require("./routes/customerMeetingUserRoute");
const generalMeetingRoute = require("./routes/generalMeetingRoute");
const notificationRoute = require("./routes/notificationRoute");

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

                                                                                  // Serve the uploads directory
                                                                                  app.use("/uploads", express.static(path.join(__dirname, "uploads")));

                                                                                  // Login route
                                                                                  app.post("/", loginRoute);

                                                                                  app.use("/notices", isLoggedIn, noticesRoute);
                                                                                  app.use("/documents", isLoggedIn, documentsRoute);
                                                                                  app.use("/users", isLoggedIn, usersRoute);
                                                                                  app.use("/suppliers", isLoggedIn, suppliersRoute);
                                                                                  app.use("/products", isLoggedIn, productsRoute);
                                                                                  app.use("/orders", isLoggedIn, ordersRoute);
                                                                                  app.use("/userProductsRequests", isLoggedIn, userProductsRequests);
                                                                                  app.use("/getRequests", isLoggedIn, getRequests);
                                                                                  app.use("/email", isLoggedIn, emailRoute);
                                                                                  app.use("/constraints", isLoggedIn, constraintsRoute);
                                                                                  app.use("/meetings", isLoggedIn, meetingsRoute);
                                                                                  app.use("/customerMeetingsAdmin", isLoggedIn, customerMeetingAdminRoutes);
                                                                                  app.use("/customerMeetingsUser", isLoggedIn, customerMeetingUserRoutes);
                                                                                  app.use("/generalMeetings", isLoggedIn, generalMeetingRoute);
                                                                                  app.use("/notification", isLoggedIn, notificationRoute);

                                                                                  // Error handling for 404
                                                                                  app.use((req, res, next) => {
                                                                                    res.status(404).json({ message: "Route not found" });
                                                                                    });

                                                                                    app.listen(port, () => {
                                                                                      console.log(`Server running on http://localhost:${port}`);
                                                                                      });