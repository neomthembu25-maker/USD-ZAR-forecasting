# =====================================================================
# Build the optional regression predictor files used by
# usdzar_forecasting.R (section 10).
#
# Output (both in ./data, dates as month/day/year, first of month):
#   predictors_fred.csv        dxy, spread, brl   (downloaded from FRED)
#   predictors_investing.csv   gold, oil, vix     (from Investing.com CSVs)
#
# For the Investing.com set, download each series as a MONTHLY CSV and save
# it in ./data with these names:
#   Gold Futures Historical Data.csv
#   Brent Oil Futures Historical Data.csv
#   CBOE Volatility Index Historical Data.csv
# =====================================================================

suppressPackageStartupMessages(library(tidyverse))
dir.create("data", showWarnings = FALSE)

# Inner-join a list of (Date, value) tibbles and write them in the format
# expected by usdzar_forecasting.R
write_predictors <- function(series, file) {
  out <- purrr::reduce(series, inner_join, by = "Date") %>%
    drop_na() %>%
    arrange(Date)
  cat(sprintf("%s: %d rows, %s to %s\n", file, nrow(out),
              format(min(out$Date)), format(max(out$Date))))
  write.csv(mutate(out, Date = format(Date, "%m/%d/%Y")), file, row.names = FALSE)
  invisible(out)
}


# ---- A. FRED (free, no login) ---------------------------------------
# Month-END values, to match the monthly close used for USD/ZAR.
get_fred <- function(id, name) {
  url <- sprintf(paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?",
                        "id=%s&cosd=2010-01-01&fq=Monthly&fam=eop"), id)
  df  <- read.csv(url, na.strings = c(".", ""))
  out <- tibble(Date  = floor_date(ymd(df[[1]]), "month"),
                value = as.numeric(df[[2]]))
  cat(sprintf("%-8s %3d rows | %s to %s | NA values: %d\n", name, nrow(out),
              format(min(out$Date)), format(max(out$Date)), sum(is.na(out$value))))
  names(out)[2] <- name
  out
}

tryCatch({
  dxy  <- get_fred("DTWEXBGS",        "dxy")    # broad US dollar index
  us10 <- get_fred("GS10",            "us10")   # US 10-year Treasury yield
  za10 <- get_fred("IRLTLT01ZAM156N", "za10")   # SA 10-year government bond yield
  brl  <- get_fred("DEXBZUS",         "brl")    # Brazilian real per USD (EM proxy)

  fred <- purrr::reduce(list(dxy, us10, za10, brl), inner_join, by = "Date") %>%
    mutate(spread = za10 - us10) %>%            # SA minus US yield differential
    select(Date, dxy, spread, brl)
  write_predictors(list(fred), "data/predictors_fred.csv")
}, error = function(e) message("FRED download failed: ", conditionMessage(e)))


# ---- B. Investing.com CSVs ------------------------------------------
read_inv <- function(file, name) {
  df  <- read.csv(file)
  out <- tibble(Date  = floor_date(mdy(df$Date), "month"),
                value = as.numeric(gsub(",", "", df$Price)))
  cat(sprintf("%-8s %3d rows | %s to %s | NA dates: %d | NA values: %d\n", name,
              nrow(out), format(min(out$Date, na.rm = TRUE)),
              format(max(out$Date, na.rm = TRUE)),
              sum(is.na(out$Date)), sum(is.na(out$value))))
  names(out)[2] <- name
  out
}

inv_files <- c(gold = "data/Gold Futures Historical Data.csv",
               oil  = "data/Brent Oil Futures Historical Data.csv",
               vix  = "data/CBOE Volatility Index Historical Data.csv")

if (all(file.exists(inv_files))) {
  series <- Map(read_inv, inv_files, names(inv_files))
  write_predictors(unname(series), "data/predictors_investing.csv")
} else {
  message("Investing.com files not all found in ./data - skipping predictors_investing.csv")
}
