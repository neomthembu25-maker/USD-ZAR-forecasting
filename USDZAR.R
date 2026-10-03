# =====================================================================
# USD/ZAR MONTHLY FORECASTING
# Train: Jan 2010 - Oct 2022 | Test: Nov 2022 - Sep 2026
# =====================================================================

# ---- 0. SETUP -------------------------------------------------------
pkgs <- c("tidyverse", "forecast", "tseries", "patchwork", "rugarch",  "zoo")
new  <- pkgs[!pkgs %in% rownames(installed.packages())]
if (length(new)) install.packages(new)
invisible(lapply(pkgs, library, character.only = TRUE))

set.seed(123)
dir.create("figures", showWarnings = FALSE)
save_fig <- function(p, name, w = 8, h = 4.5)
  ggsave(file.path("figures", paste0(name, ".png")), p,
         width = w, height = h, dpi = 300)

DATA_FILE <- "C:/Users/Cash/Downloads/USD_ZAR Historical Data.csv"
TRAIN_END <- c(2022, 10)


# ---- 1. DATA --------------------------------------------------------
usdzar <- read.csv(DATA_FILE) %>%
  select(Date, Price) %>%
  mutate(Date  = mdy(Date),
         Price = as.numeric(gsub(",", "", Price))) %>%
  arrange(Date)

stopifnot(!anyNA(usdzar$Date), !anyNA(usdzar$Price))

usdzar_ts <- ts(usdzar$Price,
                start     = c(year(min(usdzar$Date)), month(min(usdzar$Date))),
                frequency = 12)

train <- window(usdzar_ts, end   = TRAIN_END)
test  <- window(usdzar_ts, start = c(TRAIN_END[1], TRAIN_END[2] + 1))
h     <- length(test)
cat("Train:", length(train), "| Test:", h, "\n")


# ---- 2. HELPERS -----------------------------------------------------
mase_scale <- mean(abs(diff(as.numeric(train), lag = 12)))

metrics <- function(pred, actual = test) {
  e <- as.numeric(actual) - as.numeric(pred)
  c(RMSE = sqrt(mean(e^2)),
    MAE  = mean(abs(e)),
    MAPE = mean(abs(e / as.numeric(actual))) * 100,
    MASE = mean(abs(e)) / mase_scale)
}

as_fc <- function(m) structure(list(mean = m), class = "forecast")
next_start <- function(y) tsp(y)[2] + 1/12


# ---- 3. BENCHMARKS + CANDIDATE MODELS ------------------------------
# Random walk (no drift) = the honest benchmark for an FX rate.
rw_fc    <- naive(train, h = h)
mean_fc  <- meanf(train, h = h)
drift_fc <- rwf(train, drift = TRUE, h = h)
ses_fc   <- ses(train, h = h)
ets_fc   <- forecast(ets(train), h = h)

# ARIMA(0,1,0) explicit, NO drift
arima_fc <- forecast(Arima(train, order = c(0,1,0)), h = h)

# Auto ARIMA but WITHOUT drift (allowdrift = FALSE)
auto_fc  <- forecast(auto.arima(train, allowdrift = FALSE,
                                stepwise = FALSE, approximation = FALSE), h = h)

# Moving averages
ma_fc <- function(y, k, h) ts(rep(mean(tail(as.numeric(y), k)), h),
                              start = next_start(y), frequency = 12)
ma3_fc  <- ma_fc(train, 3,  h)
ma12_fc <- ma_fc(train, 12, h)

# Regression
lm1_fc <- forecast(tslm(train ~ trend), h = h)
lm2_fc <- forecast(tslm(train ~ trend + season), h = h)

# Neural net on differences
nnar_forecast <- function(y, h, repeats = 50) {
  fit <- nnetar(diff(y), repeats = repeats)
  ts(as.numeric(tail(y, 1)) + cumsum(as.numeric(forecast(fit, h = h)$mean)),
     start = next_start(y), frequency = 12)
}
nn_fc <- nnar_forecast(train, h, repeats = 50)


# ---- 4. TEST-SET TABLE ---------------------------------------------
fcs <- list(
  "Random walk"     = rw_fc$mean,
  "Mean"            = mean_fc$mean,
  "Drift"           = drift_fc$mean,
  "SES"             = ses_fc$mean,
  "ETS"             = ets_fc$mean,
  "ARIMA(0,1,0)"    = arima_fc$mean,
  "auto.arima"      = auto_fc$mean,
  "MA(3)"           = ma3_fc,
  "MA(12)"          = ma12_fc,
  "TSLM trend"      = lm1_fc$mean,
  "TSLM trend+seas" = lm2_fc$mean,
  "NNAR"            = nn_fc
)

comparison <- t(sapply(fcs, metrics))
comparison <- comparison[order(comparison[, "RMSE"]), ]
print(round(comparison, 3))
write.csv(round(comparison, 3), "figures/test_set_comparison.csv")


# ---- 5. DIEBOLD-MARIANO VS RANDOM WALK -----------------------------
# H0: equal predictive accuracy. Negative DM => model beats RW.
dm_test <- function(e1, e2, h = 1, power = 2) {
  e1 <- as.numeric(e1); e2 <- as.numeric(e2)
  d  <- (abs(e1)^power - abs(e2)^power)     # loss differential
  n  <- length(d)
  dbar <- mean(d)
  # Newey-West with h-1 lags
  gamma <- sapply(0:(h-1), function(k) mean((d[1:(n-k)] - dbar) * (d[(1+k):n] - dbar)))
  var_d <- (gamma[1] + 2 * sum(gamma[-1])) / n
  DM <- dbar / sqrt(var_d)
  # Harvey-Leybourne-Newbold small-sample correction
  DM_hl <- DM * sqrt((n + 1 - 2*h + h*(h-1)/n) / n)
  p <- 2 * pt(-abs(DM_hl), df = n - 1)
  c(DM = DM_hl, p = p)
}

rw_err <- as.numeric(test) - as.numeric(rw_fc$mean)

dm_table <- t(sapply(fcs, function(p) dm_test(rw_err, as.numeric(test) - as.numeric(p))))
dm_table <- dm_table[order(dm_table[, "DM"]), ]
print(round(dm_table, 3))
write.csv(round(dm_table, 3), "figures/dm_vs_random_walk.csv")


# ---- 6. ROLLING-ORIGIN CV ------------------------------------------
cv_funs <- list(
  "Random walk" = function(y, h) naive(y, h = h),
  "Drift"       = function(y, h) rwf(y, drift = TRUE, h = h),
  "SES"         = function(y, h) ses(y, h = h),
  "ARIMA(0,1,0)"= function(y, h) as_fc(forecast(Arima(y, order = c(0,1,0)), h = h)$mean),
  "MA(3)"       = function(y, h) as_fc(ma_fc(y, 3, h)),
  "TSLM"        = function(y, h) forecast(tslm(y ~ trend + season), h = h),
  "NNAR"        = function(y, h) as_fc(nnar_forecast(y, h, repeats = 10))
)

cv_rmse <- sapply(cv_funs, function(f) {
  e <- tsCV(usdzar_ts, f, h = 12, initial = 60)
  sqrt(colMeans(e^2, na.rm = TRUE))
})
cv_table <- t(cv_rmse)
print(round(cv_table[, c("h=1","h=3","h=6","h=12")], 3))
write.csv(round(cv_table, 3), "figures/rolling_origin_rmse.csv")


# ---- 7. PLOTS -------------------------------------------------------
# Forecast comparison
hist_df <- tibble(Time = as.numeric(time(window(train, start = c(2018,1)))),
                  Value = as.numeric(window(train, start = c(2018,1))))
fc_df <- tibble(
  Time = as.numeric(time(test)),
  Actual = as.numeric(test),
  "Random walk" = as.numeric(rw_fc$mean),
  "MA(3)"       = as.numeric(ma3_fc),
  "ARIMA(0,1,0)"= as.numeric(arima_fc$mean),
  "NNAR"        = as.numeric(nn_fc)
) %>% pivot_longer(-Time, names_to = "Model", values_to = "Value")

p_cmp <- ggplot() +
  geom_line(data = hist_df, aes(Time, Value), colour = "grey50") +
  geom_line(data = fc_df,
            aes(Time, Value, colour = Model, linewidth = Model == "Actual")) +
  scale_linewidth_manual(values = c("TRUE" = 1.2, "FALSE" = 0.7), guide = "none") +
  labs(title = "Test-set forecasts", x = "Year", y = "ZAR per USD", colour = "") +
  theme_minimal()
save_fig(p_cmp, "05_model_comparison")
p_cmp

# Rolling-origin RMSE plot
cv_long <- as.data.frame(cv_table) %>%
  rownames_to_column("Model") %>%
  pivot_longer(-Model, names_to = "Horizon", values_to = "RMSE") %>%
  mutate(Horizon = as.integer(sub("h=", "", Horizon)))

p_cv <- ggplot(cv_long, aes(Horizon, RMSE, colour = Model)) +
  geom_line(linewidth = 0.9) + geom_point() +
  scale_x_continuous(breaks = 1:12) +
  labs(title = "Rolling-origin RMSE by horizon", y = "RMSE (ZAR)") +
  theme_minimal()
save_fig(p_cv, "06_rolling_origin")


# ---- 8. EXTERNAL PREDICTORS (OPTIONAL) -----------------------------
get_fred <- function(id, name) {
  url <- sprintf(
    "https://fred.stlouisfed.org/graph/fredgraph.csv?id=%s&cosd=2010-01-01&coed=2026-12-31&fq=Monthly&fam=eop",
    id
  )
  df  <- read.csv(url, na.strings = c(".", ""))
  out <- tibble(Date  = floor_date(ymd(df[[1]]), "month"),
                value = as.numeric(df[[2]]))
  names(out)[2] <- name
  out
}

if (requireNamespace("lubridate", quietly = TRUE)) {
  dxy  <- get_fred("DTWEXBGS",        "dxy")
  us10 <- get_fred("GS10",            "us10")
  za10 <- get_fred("IRLTLT01ZAM156N", "za10")
  brl  <- get_fred("DEXBZUS",         "brl")
  
  px <- purrr::reduce(list(dxy, us10, za10, brl), inner_join, by = "Date") %>%
    mutate(spread = za10 - us10) %>%
    select(Date, dxy, spread, brl) %>%
    drop_na() %>%
    arrange(Date)
  
  dat <- usdzar %>%
    mutate(Date = floor_date(Date, "month")) %>%
    inner_join(px, by = "Date") %>%
    mutate(dy   = c(NA, diff(log(Price))),
           prev = lag(Price))
  
  for (v in c("dxy","spread","brl"))
    dat[[paste0(v, "_l1")]] <- lag(c(NA, diff(log(dat[[v]]))), 1)
  
  lag_names <- paste0(c("dxy","spread","brl"), "_l1")
  tr <- dat$Date <= as.Date(sprintf("%d-%02d-01", TRAIN_END[1], TRAIN_END[2]))
  
  fit_x <- lm(reformulate(lag_names, response = "dy"),
              data = dat[tr, ] %>% drop_na(dy, all_of(lag_names)))
  print(summary(fit_x))
  
  tst <- dat[!tr, ] %>% drop_na(dy, prev, all_of(lag_names))
  pred_reg   <- tst$prev * exp(predict(fit_x, newdata = tst))
  pred_naive <- tst$prev
  
  print(rbind(Naive_1step      = metrics(pred_naive, tst$Price),
              Regression_1step = metrics(pred_reg,   tst$Price)))
}


# ---- 9. GARCH (volatility) -----------------------------------------
ret  <- diff(log(usdzar_ts))
spec <- ugarchspec(
  variance.model     = list(model = "sGARCH", garchOrder = c(1,1)),
  mean.model         = list(armaOrder = c(0,0), include.mean = FALSE),
  distribution.model = "std")
fit_g <- ugarchfit(spec, data = as.numeric(ret))
print(fit_g)
cat("\nGARCH vol forecast (next 12 months):\n")
print(sigma(ugarchforecast(fit_g, n.ahead = 12)))


# ---- 10. FINAL FORECAST (random walk, full sample) -----------------
final_fit <- Arima(usdzar_ts, order = c(0,1,0))
fc_final  <- forecast(final_fit, h = 12, level = c(80, 95))
print(fc_final)

p_final <- autoplot(fc_final, include = 60) +
  labs(title = "12-month USD/ZAR forecast: random walk",
       x = "Year", y = "ZAR per USD") +
  theme_minimal()
save_fig(p_final, "07_final_forecast")
p_final

