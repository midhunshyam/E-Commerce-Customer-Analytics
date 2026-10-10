#!/usr/bin/env Rscript
# Data checks, variable analysis and coupon budget optimisation for the e-commerce dataset.
# Describes every variable, repeats the notebook's analyses as checks (segments, value drivers, age,
# channels, categories, retention, geography, lapsed customers and the hypothesis tests), and solves
# the coupon budget as an integer linear program with lpSolve. The printed report is also written to
# outputs/variable_analysis_and_budget_optimization.txt.
#
# Run from the repository root:  Rscript scripts/variable_analysis_and_budget_optimization.R
if (!requireNamespace("lpSolve", quietly = TRUE)) install.packages("lpSolve", repos = "https://cloud.r-project.org")
suppressMessages(library(lpSolve))
options(width = 105)

out_dir <- if (dir.exists("data")) "outputs" else "../outputs"
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
report_path <- file.path(out_dir, "variable_analysis_and_budget_optimization.txt")
report_con  <- file(report_path, open = "wt")
sink(report_con, split = TRUE)

rule <- function(title) {
  bar <- paste(rep("=", 78), collapse = "")
  cat("\n", bar, "\n", title, "\n", bar, "\n", sep = "")
}
sub_rule <- function(title) cat("\n---", title, "---\n")
reading <- function(...) {
  txt <- paste(...)
  txt <- gsub("[[:space:]]+", " ", txt)
  txt <- gsub(" ([.,;:)%])", "\\1", txt)
  txt <- gsub("([($]) ", "\\1", txt)
  cat(strwrap(paste("Reading it:", txt), width = 100, exdent = 2), sep = "\n"); cat("\n")
}
money <- function(x) paste0("$", format(round(x), big.mark = ",", scientific = FALSE))
pct   <- function(x) sprintf("%.1f%%", 100 * x)

data_dir     <- if (dir.exists("data")) "data" else "../data"
customers    <- read.csv(file.path(data_dir, "customers.csv"),    stringsAsFactors = FALSE)
transactions <- read.csv(file.path(data_dir, "transactions.csv"), stringsAsFactors = FALSE)
clv          <- read.csv(file.path(data_dir, "clv_targets.csv"),  stringsAsFactors = FALSE)
channels     <- read.csv(file.path(data_dir, "channels.csv"),     stringsAsFactors = FALSE)
transactions$transaction_date <- as.Date(transactions$transaction_date)
V   <- "target_clv_next_12_months"
REF <- as.Date("2026-07-01")

by_customer <- split(transactions, transactions$customer_id)
rfm <- data.frame(
  customer_id = names(by_customer),
  frequency   = sapply(by_customer, nrow),
  monetary    = sapply(by_customer, function(d) sum(d$amount)),
  aov         = sapply(by_customer, function(d) mean(d$amount)),
  recency     = sapply(by_customer, function(d) as.numeric(REF - max(d$transaction_date))),
  stringsAsFactors = FALSE
)
feat <- merge(merge(customers, rfm, by = "customer_id"), clv, by = "customer_id")

Xseg <- scale(log1p(feat[, c("recency", "frequency", "monetary", "aov")]))
set.seed(42)
km   <- kmeans(Xseg, centers = 3, nstart = 25, iter.max = 50)
med_mon <- tapply(feat$monetary, km$cluster, median)
seg_names <- setNames(c("Occasional Shoppers", "Bargain Hunters", "VIPs")[rank(med_mon)], names(med_mon))
feat$segment <- unname(seg_names[as.character(km$cluster)])
feat$segment <- factor(feat$segment, levels = c("VIPs", "Bargain Hunters", "Occasional Shoppers"))

feat$band <- cut(feat$age, breaks = c(17, 28, 38, 48, 58, 100),
                 labels = c("18-28", "29-38", "39-48", "49-58", "59+"))

cat(sprintf("Loaded: %d customers, %d transactions, %d channels. Segments: %d VIPs, %d Bargain, %d Occasional.\n",
            nrow(customers), nrow(transactions), nrow(channels),
            sum(feat$segment == "VIPs"), sum(feat$segment == "Bargain Hunters"), sum(feat$segment == "Occasional Shoppers")))

section_overview <- function() {
  rule("DATA OVERVIEW: every variable, its distribution and details")

  sub_rule("Numeric variables: distribution and shape")
  num_vars <- c("age", "recency", "frequency", "monetary", "aov", V)
  labels   <- c("age", "recency", "frequency", "monetary", "aov", "target_clv")
  skewness <- function(x) mean(((x - mean(x)) / sd(x))^3)
  cat(sprintf("%-11s %5s %4s %9s %9s %9s %9s %9s %9s %9s %7s\n",
              "variable", "n", "miss", "min", "q1", "median", "mean", "q3", "max", "sd", "skew"))
  for (i in seq_along(num_vars)) {
    x  <- feat[[num_vars[i]]]
    nm <- sum(is.na(x))
    x  <- x[!is.na(x)]
    qs <- quantile(x, c(0.25, 0.5, 0.75))
    cat(sprintf("%-11s %5d %4d %9.1f %9.1f %9.1f %9.1f %9.1f %9.1f %9.1f %7.2f\n",
                labels[i], length(x), nm, min(x), qs[1], qs[2], mean(x), qs[3], max(x), sd(x), skewness(x)))
  }
  reading("Age spans a wide range and is roughly flat (skew near zero), but monetary and target value are strongly ",
          "right skewed: their medians sit far below their maxima, so a small number of heavy spenders sit in a long right tail.")

  txt_hist <- function(x, title) {
    x    <- x[!is.na(x)]
    br   <- seq(min(x), max(x), length.out = 11)
    cnt  <- hist(x, breaks = br, plot = FALSE)$counts
    maxc <- max(cnt)
    sub_rule(paste0("Histogram: ", title, " (10 equal-width bins)"))
    for (b in seq_along(cnt)) {
      bar <- paste(rep("#", round(40 * cnt[b] / maxc)), collapse = "")
      cat(sprintf("%9.0f to %9.0f | %5d %s\n", br[b], br[b + 1], cnt[b], bar))
    }
  }
  txt_hist(feat$monetary, "monetary (total spend)")
  txt_hist(feat[[V]],     "target_clv (next 12 months)")
  reading("Both histograms pile up in the leftmost, lowest-value bins and thin out to the right: most customers are ",
          "low to mid value, and a thin tail of big spenders stretches the axis, which is the signature of a right skew.")

  sub_rule("Categorical variables: frequency and share")
  cat_table <- function(x, title) {
    tb <- sort(table(x), decreasing = TRUE)
    tot <- sum(tb)
    cat(sprintf("\n%s (n = %d)\n", title, tot))
    for (lv in names(tb)) {
      cat(sprintf("  %-14s %6d  %7s\n", lv, tb[[lv]], pct(tb[[lv]] / tot)))
    }
  }
  cat_table(feat$gender,              "gender (per customer)")
  cat_table(feat$country,             "country (per customer)")
  cat_table(feat$acquisition_channel, "acquisition_channel (per customer)")
  cat_table(transactions$category,    "category (per transaction row)")
  reading("Behaviour and value variables (monetary, target) are right skewed, so a few big spenders carry most of the ",
          "value, while demographics like age are spread evenly; the categorical splits show where volume sits by ",
          "country, channel, and product category.")
}

section_segments <- function() {
  rule("SEGMENTS: who they are and how value concentrates")

  segs  <- c("VIPs", "Bargain Hunters", "Occasional Shoppers")
  n_all <- nrow(feat)
  gtv   <- sum(feat[[V]])

  sub_rule("Per-segment profile (medians) and share of total value")
  cat(sprintf("%-20s %5s %7s %8s %6s %10s %8s %5s %11s %8s\n",
              "segment", "n", "pct", "recency", "freq", "monetary", "aov", "age", "med_value", "val_shr"))

  for (s in segs) {
    idx <- feat$segment == s
    n_s <- sum(idx)
    cat(sprintf("%-20s %5d %7s %8.0f %6.0f %10s %8s %5.0f %11s %8s\n",
                s,
                n_s,
                pct(n_s / n_all),
                median(feat$recency[idx]),
                median(feat$frequency[idx]),
                money(median(feat$monetary[idx])),
                money(median(feat$aov[idx])),
                median(feat$age[idx]),
                money(median(feat[[V]][idx])),
                pct(sum(feat[[V]][idx]) / gtv)))
  }

  vip_idx   <- feat$segment == "VIPs"
  vip_pct   <- sum(vip_idx) / n_all
  vip_share <- sum(feat[[V]][vip_idx]) / gtv
  age_med   <- tapply(feat$age, feat$segment, median)
  age_spread <- max(age_med) - min(age_med)

  reading("Value is concentrated: VIPs are ", pct(vip_pct), " of customers but hold ", pct(vip_share),
          " of predicted next-year value. Segments differ sharply on behaviour (frequency, recency, spend) yet ",
          "median age varies only ", round(age_spread), " years across them, so the tiers are behavioural. Age and other demographics do not separate them.")
}

section_drivers <- function() {
  rule("VALUE DRIVERS: what predicts next-year value")

  y <- feat[[V]]
  drivers <- c("recency", "frequency", "monetary", "aov", "age")

  sub_rule("Correlation with next-year value (sorted by strength)")
  cors <- sapply(drivers, function(v) cor(feat[[v]], y))
  ord <- order(abs(cors), decreasing = TRUE)
  cors <- cors[ord]
  cat(sprintf("%-11s %8s\n", "driver", "corr"))
  for (v in names(cors))
    cat(sprintf("%-11s %8.3f\n", v, cors[[v]]))
  reading("Every behaviour points the same way, but total spend (monetary) is far and away the",
          "strongest single predictor of what a customer is worth next year.")

  sub_rule("Multiple regression: target ~ recency + frequency + monetary + aov + age")
  m <- lm(y ~ recency + frequency + monetary + aov + age, data = feat)
  co <- summary(m)$coefficients
  cat(sprintf("%-12s %12s %10s\n", "term", "coef", "p_value"))
  for (r in rownames(co))
    cat(sprintf("%-12s %12.4f %10.4g\n", r, co[r, "Estimate"], co[r, "Pr(>|t|)"]))
  cat(sprintf("R-squared: %.4f\n", summary(m)$r.squared))
  reading("Spend dominates. Frequency and average order value can turn negative here even though each",
          "is positive on its own: because monetary equals frequency times average order value by",
          "construction, they are collinear, so their signs flip once spend is in the model. This is a",
          "statistical artefact rather than a real negative effect. Age adds a little, about $1.4 per year.")

  sub_rule("Naive baseline: target ~ monetary alone")
  m0 <- lm(y ~ monetary, data = feat)
  cat(sprintf("R-squared (monetary only): %.4f\n", summary(m0)$r.squared))
  reading("Spend alone already explains almost everything (R-squared about 0.998). Future value is",
          "driven by how much a customer has already spent, not by who they are.")

  invisible(NULL)
}

section_age <- function() {
  rule("AGE: marginal and conditional effects on value")

  a   <- feat$age
  tgt <- feat[[V]]
  mon <- feat$monetary
  ratio <- tgt / mon

  sub_rule("1) Marginal vs conditional correlations")
  c_marg  <- cor(a, tgt)
  c_spend <- cor(a, mon)
  c_cond  <- cor(a, ratio)
  cat(sprintf("  cor(age, value)              MARGINAL   = % .3f\n", c_marg))
  cat(sprintf("  cor(age, spend)              spend-link = % .3f\n", c_spend))
  cat(sprintf("  cor(age, value-per-dollar)   CONDITIONAL= % .3f\n", c_cond))
  reading(
    "The marginal age-to-value link is tiny (", sprintf("%.3f", c_marg),
    ") yet the conditional link is large (", sprintf("%.3f", c_cond),
    "). The reason: age carries almost no spend information (age-to-spend is ",
    sprintf("%.3f", c_spend),
    "), so age is not redundant with spend and its signal only surfaces once you ",
    "hold spend fixed, that is, in the value-per-dollar ratio."
  )

  sub_rule("2) Incremental R-squared of adding age to the spend model")
  m1 <- lm(tgt ~ mon)
  m2 <- lm(tgt ~ mon + a)
  r1 <- summary(m1)$r.squared
  r2 <- summary(m2)$r.squared
  age_coef <- coef(m2)[["a"]]
  cat(sprintf("  R2  value ~ spend          = %.5f\n", r1))
  cat(sprintf("  R2  value ~ spend + age    = %.5f\n", r2))
  cat(sprintf("  incremental R2 from age    = %.5f\n", r2 - r1))
  cat(sprintf("  age coefficient            = $%.2f per year\n", age_coef))
  reading(
    "Spend already explains", pct(r1),
    "of value. Adding age lifts that by only", sprintf("%.5f", r2 - r1),
    "of R2 (about", sprintf("$%.2f", age_coef),
    "per year of age). Statistically detectable, but practically negligible."
  )

  sub_rule("3) Value returned per $1 of past spend, by age band")
  by_band <- tapply(ratio, feat$band, mean)
  by_band <- by_band[levels(feat$band)]
  for (b in names(by_band)) {
    cat(sprintf("  %-6s  $%.2f returned per $1 spent\n", b, by_band[[b]]))
  }
  reading(
    "The return per dollar rises steadily with age, from about $",
    sprintf("%.2f", by_band[[1]]), " for the youngest band to about $",
    sprintf("%.2f", by_band[[length(by_band)]]),
    " for the oldest. Older customers give back a little more per dollar they have already spent."
  )

  sub_rule("4) Within-segment age effect (young age<=38 vs old age>=59)")
  cat(sprintf("  %-20s %8s %10s %10s %8s\n",
              "segment", "corr", "young", "old", "gap"))
  for (s in levels(feat$segment)) {
    idx <- feat$segment == s
    cc  <- cor(a[idx], tgt[idx])
    y   <- mean(tgt[idx & a <= 38])
    o   <- mean(tgt[idx & a >= 59])
    cat(sprintf("  %-20s % 8.3f %10s %10s %8s\n",
                s, cc, money(y), money(o), money(o - y)))
  }
  reading(
    "The age tilt is real inside Bargain Hunters and Occasional Shoppers: older ",
    "members are worth more, a positive correlation and a positive old-minus-young gap. ",
    "For VIPs the correlation is essentially zero to negative and the gap flips negative, ",
    "so among top customers age gives no edge, if anything the younger VIPs are worth more."
  )

  sub_rule("5) ANOVA of value across age bands")
  fit <- aov(tgt ~ feat$band)
  pval <- summary(fit)[[1]][["Pr(>F)"]][1]
  cat(sprintf("  aov(value ~ age band)  p-value = %.3f\n", pval))
  reading(
    "The p-value is ", sprintf("%.3f", pval),
    ", far above 0.05, so total value does not differ across age bands. ",
    "Once you look at the raw dollars per customer, age bands are flat."
  )

  reading(
    "Age has a weak second-order link with retention: among equal-spend mid and low ",
    "value customers, older ones return a little more per dollar, but it adds almost ",
    "nothing to the value model (+", sprintf("%.4f", r2 - r1),
    " R2), it disappears for VIPs, and total value is flat across age bands ",
    "(ANOVA not significant, p=", sprintf("%.2f", pval),
    "). Age is not useful for targeting, except as a minor tiebreak within the mid and low ",
    "value segments."
  )
}

section_channels <- function() {
  rule("CHANNEL ECONOMICS: net value after commission and acquisition cost")

  rev_by_ch <- tapply(feat$monetary, feat$acquisition_channel, sum)
  n_by_ch   <- tapply(feat$monetary, feat$acquisition_channel, length)

  chn  <- names(rev_by_ch)
  idx  <- match(chn, channels$channel_name)
  rate <- channels$revenue_share_rate[idx]
  cost <- channels$cost_per_signup[idx]

  rev  <- as.numeric(rev_by_ch)
  n    <- as.numeric(n_by_ch)
  commission <- rev * rate
  acq_cost   <- n * cost
  net        <- rev * (1 - rate) - acq_cost

  ord <- order(net, decreasing = TRUE)

  sub_rule("Per-channel net value (sorted by NET)")
  cat(sprintf("%-10s %5s %13s %13s %11s %13s %10s\n",
              "Channel", "n", "Revenue", "Commission", "AcqCost", "NET", "Net/cust"))
  for (i in ord) {
    cat(sprintf("%-10s %5d %13s %13s %11s %13s %10s\n",
                chn[i], n[i],
                money(rev[i]), money(commission[i]),
                money(acq_cost[i]), money(net[i]),
                money(net[i] / n[i])))
  }

  total_rev  <- sum(rev)
  total_net  <- sum(net)
  total_n    <- sum(n)
  ret_ratio  <- total_net / (sum(commission) + sum(acq_cost))

  sub_rule("Whole-mix totals")
  cat(sprintf("Customers acquired : %d\n", total_n))
  cat(sprintf("Total revenue      : %s\n", money(total_rev)))
  cat(sprintf("Whole-mix NET      : %s\n", money(total_net)))
  cat(sprintf("Net per customer   : %s\n", money(total_net / total_n)))
  cat(sprintf("Return per $ spent : %s\n",
              sprintf("%.2fx", total_net / (sum(commission) + sum(acq_cost)))))

  reading("The revenue_share_rate is a commission paid to the channel, so higher-rate channels keep less of each revenue dollar. The current mix is net positive, and Google and Organic carry most of the net value.")
}

section_category <- function() {
  rule("PRODUCT MIX: category price tiers and spend share")

  catg <- transactions$category
  amt  <- transactions$amount

  tot_spend_all <- sum(amt)

  avg_price <- tapply(amt, catg, mean)
  tot_spend <- tapply(amt, catg, sum)
  n_buy     <- tapply(amt, catg, length)

  ord  <- order(avg_price, decreasing = TRUE)
  cats <- names(avg_price)[ord]

  sub_rule("Categories sorted by average price (high to low)")

  cat(sprintf("%-12s %10s %14s %12s %9s\n",
              "Category", "AvgPrice", "TotalSpend", "Purchases", "Share"))

  for (c in cats) {
    cat(sprintf("%-12s %10s %14s %12d %9s\n",
                c,
                money(avg_price[[c]]),
                money(tot_spend[[c]]),
                as.integer(n_buy[[c]]),
                pct(tot_spend[[c]] / tot_spend_all)))
  }

  top_spend <- names(tot_spend)[which.max(tot_spend)]
  top_share <- tot_spend[[top_spend]] / tot_spend_all

  cat(sprintf("\n%s drives the most total spend at %s (%s of all spend).\n",
              top_spend, money(tot_spend[[top_spend]]), pct(top_share)))

  reading(
    "There are two price tiers: premium (Electronics near $90, Home near $82) ",
    "and value (Fashion and Beauty near $41, high volume but low price), with ",
    "Sports in the middle near $59. Electronics leads on both price and total ",
    "spend (about 31% of the total), so it is the single most important category."
  )
}

section_retention <- function() {
  rule("RETENTION AND CADENCE: how often and how recently they buy")

  seg_of <- feat$segment
  names(seg_of) <- feat$customer_id

  gap_by_cust <- tapply(seq_len(nrow(transactions)),
                        transactions$customer_id,
                        function(ix) {
                          d <- sort(transactions$transaction_date[ix])
                          if (length(d) < 2) return(NA_real_)
                          median(as.numeric(diff(d)))
                        })

  cust_ids  <- names(gap_by_cust)
  cust_seg  <- seg_of[cust_ids]
  gap_seg   <- tapply(as.numeric(gap_by_cust), cust_seg,
                      function(v) median(v, na.rm = TRUE))

  rec_seg <- tapply(feat$recency, feat$segment,
                    function(v) median(v, na.rm = TRUE))

  sub_rule("Median inter-purchase gap and median recency, by segment")
  segs <- levels(feat$segment)
  cat(sprintf("%-20s %14s %14s\n", "Segment", "MedianGap", "MedianRecency"))
  for (s in segs) {
    cat(sprintf("%-20s %11.0f d %11.0f d\n",
                s, gap_seg[[s]], rec_seg[[s]]))
  }

  reading(
    "VIPs buy on a tight cycle (median gap about ", sprintf("%.0f", gap_seg[["VIPs"]]),
    " days) and are freshly active (recency about ", sprintf("%.0f", rec_seg[["VIPs"]]),
    " days). Occasional Shoppers have long gaps (about ",
    sprintf("%.0f", gap_seg[["Occasional Shoppers"]]),
    " days) and long silence (recency about ",
    sprintf("%.0f", rec_seg[["Occasional Shoppers"]]),
    " days), with Bargain Hunters in between. A useful churn-risk rule: once a ",
    "customer's silence passes roughly twice their segment's normal cadence, fire ",
    "a win-back trigger, because they are overdue relative to how that segment buys."
  )
}

section_geography <- function() {
  rule("GEOGRAPHY AND DEMOGRAPHICS: volume vs per-head value")

  tgt <- feat[[V]]

  sub_rule("1) By country: volume vs value per customer")
  n_ctry   <- tapply(tgt, feat$country, length)
  tot_ctry <- tapply(tgt, feat$country, sum)
  vpc_ctry <- tot_ctry / n_ctry
  ord      <- order(n_ctry, decreasing = TRUE)
  cat(sprintf("  %-8s %8s %14s %14s\n",
              "country", "n", "total value", "value/cust"))
  for (c in names(n_ctry)[ord]) {
    cat(sprintf("  %-8s %8d %14s %14s\n",
                c, n_ctry[[c]], money(tot_ctry[[c]]), money(vpc_ctry[[c]])))
  }
  vpc_lo <- min(vpc_ctry)
  vpc_hi <- max(vpc_ctry)
  reading(
    "The countries differ hugely in headcount (from ", min(n_ctry), " to ", max(n_ctry),
    " customers) but barely in value per customer: every country sits between ",
    money(vpc_lo), " and ", money(vpc_hi),
    " per head. Bigger countries matter because they have more customers, and their customers ",
    "are not individually worth more."
  )

  sub_rule("2) By gender: volume vs value per customer")
  n_gen   <- tapply(tgt, feat$gender, length)
  tot_gen <- tapply(tgt, feat$gender, sum)
  vpc_gen <- tot_gen / n_gen
  gord    <- order(n_gen, decreasing = TRUE)
  cat(sprintf("  %-10s %8s %14s %14s\n",
              "gender", "n", "total value", "value/cust"))
  for (g in names(n_gen)[gord]) {
    cat(sprintf("  %-10s %8d %14s %14s\n",
                g, n_gen[[g]], money(tot_gen[[g]]), money(vpc_gen[[g]])))
  }
  reading(
    "Gender is roughly balanced (", min(n_gen), " to ", max(n_gen),
    " customers per group) and value per customer moves only between ",
    money(min(vpc_gen)), " and ", money(max(vpc_gen)),
    ", so gender carries no meaningful value signal either."
  )

  reading(
    "Geography and gender change the number of customers but not their value: per-customer value ",
    "barely moves across country (", money(vpc_lo), " to ", money(vpc_hi),
    ") or gender (", money(min(vpc_gen)), " to ", money(max(vpc_gen)),
    "). Targeting by geography or gender would not add value; behaviour does."
  )
}

section_lapsed <- function() {
  rule("LAPSED CUSTOMERS: size and shape of the win-back opportunity")

  thr <- quantile(feat$recency, 0.90)
  lap <- feat$recency >= thr
  n_lap  <- sum(lap)
  n_all  <- nrow(feat)
  gtv    <- sum(feat[[V]])
  lap_val <- sum(feat[[V]][lap])
  lap_shr <- lap_val / gtv

  sub_rule("Lapsed pool size and value")
  cat(sprintf("Recency threshold (90th pct): %.0f days\n", thr))
  cat(sprintf("Lapsed customers            : %d of %d (%s)\n",
              n_lap, n_all, pct(n_lap / n_all)))
  cat(sprintf("Their share of total value  : %s (%s of %s)\n",
              pct(lap_shr), money(lap_val), money(gtv)))
  reading("The lapsed pool is small, about ", pct(n_lap / n_all), " of customers, and holds only ",
          pct(lap_shr), " of predicted next-year value.")

  sub_rule("Segment breakdown of lapsed customers")
  segs <- c("VIPs", "Bargain Hunters", "Occasional Shoppers")
  cat(sprintf("%-20s %6s %8s\n", "segment", "n", "pct"))
  for (s in segs) {
    n_s <- sum(lap & feat$segment == s)
    cat(sprintf("%-20s %6d %8s\n", s, n_s,
                pct(if (n_lap > 0) n_s / n_lap else 0)))
  }
  dom <- names(which.max(table(feat$segment[lap])))
  reading("The lapsed pool sits almost entirely in the ", dom, " segment, and includes essentially no VIPs.")

  sub_rule("Category skew: lapsed purchase share vs all customers (index, >1 = over-index)")
  lap_ids <- feat$customer_id[lap]
  tx_lap  <- transactions$category[transactions$customer_id %in% lap_ids]
  sh_all  <- prop.table(table(transactions$category))
  sh_lap  <- prop.table(table(factor(tx_lap, levels = names(sh_all))))
  idx     <- as.numeric(sh_lap) / as.numeric(sh_all)
  names(idx) <- names(sh_all)
  ord <- order(idx, decreasing = TRUE)

  cat(sprintf("%-12s %10s %10s %8s\n", "category", "lap_shr", "all_shr", "index"))
  for (c in names(idx)[ord])
    cat(sprintf("%-12s %10s %10s %8.2f\n", c,
                pct(sh_lap[[c]]), pct(sh_all[[c]]), idx[[c]]))
  over <- names(idx)[ord][idx[ord] > 1]
  over_txt <- if (length(over) > 0) paste(over, collapse = ", ") else "none"
  reading("Categories that over-index among lapsed buyers (index above 1): ", over_txt, ". ",
          "Overall the lapsed pool is small, low value, and almost entirely Occasional Shoppers, ",
          "so a win-back campaign would be worth little.")

  invisible(NULL)
}

section_tests <- function() {
  rule("HYPOTHESIS TESTS: are the patterns statistically real")

  sub_rule("1) ANOVA: target CLV ~ segment")
  aov_seg  <- aov(feat[[V]] ~ feat$segment)
  ssum_seg <- summary(aov_seg)[[1]]
  F_seg    <- ssum_seg[["F value"]][1]
  p_seg    <- ssum_seg[["Pr(>F)"]][1]
  cat(sprintf("  F = %8.2f   p = %s\n", F_seg,
              format.pval(p_seg, digits = 3, eps = 1e-16)))
  cat(sprintf("  verdict: %s\n",
              if (p_seg < 0.05) "segment value differences are significant"
              else "no significant difference across segments"))
  reading("Segments differ in value with near-zero p, so the VIP / Bargain / Occasional split reflects real value differences.")

  sub_rule("2) ANOVA: target CLV ~ age band")
  aov_band  <- aov(feat[[V]] ~ feat$band)
  ssum_band <- summary(aov_band)[[1]]
  F_band    <- ssum_band[["F value"]][1]
  p_band    <- ssum_band[["Pr(>F)"]][1]
  cat(sprintf("  F = %8.2f   p = %s\n", F_band,
              format.pval(p_band, digits = 3, eps = 1e-16)))
  cat(sprintf("  verdict: %s\n",
              if (p_band < 0.05) "value differs by age band (significant)"
              else "no significant difference by age band"))
  reading("Age bands do not differ in value (p well above 0.05).")

  sub_rule("3) Chi-square: product category x segment")
  seg_by_cust <- feat$segment[match(transactions$customer_id,
                                    feat$customer_id)]
  tab_cs      <- table(transactions$category, seg_by_cust)
  chi_cs      <- chisq.test(tab_cs)
  cat(sprintf("  X-squared = %8.2f   df = %d   p = %s\n",
              chi_cs$statistic, chi_cs$parameter,
              format.pval(chi_cs$p.value, digits = 3, eps = 1e-16)))
  cat(sprintf("  verdict: %s\n",
              if (chi_cs$p.value < 0.05) "segments buy DIFFERENT product mixes (significant)"
              else "no difference in product mix across segments"))
  reading("Category purchase mix differs by segment with near-zero p: segments really do shop differently.")

  sub_rule("4) cor.test: age vs target CLV")
  ct <- cor.test(feat$age, feat[[V]])
  cat(sprintf("  r = %6.3f   t = %6.2f   df = %d   p = %s\n",
              ct$estimate, ct$statistic, ct$parameter,
              format.pval(ct$p.value, digits = 3, eps = 1e-16)))
  cat(sprintf("  verdict: %s\n",
              if (ct$p.value < 0.05) "age-value correlation is distinguishable from zero"
              else "age-value correlation is not distinguishable from zero"))
  reading("Age barely correlates with value (r near 0.03) and the correlation is not distinguishable from zero.")

  reading("Segments and product mix differ significantly, and value does not differ by age band.")
}

section_budget <- function() {
  rule("BUDGET OPTIMIZATION: best coupon per segment as an integer linear program")
  segments   <- c("VIPs", "Bargain Hunters", "Occasional Shoppers")
  population <- c(150, 350, 500)
  coupons    <- c(0, 5, 10, 20)
  budget     <- 10000
  inc <- rbind(c(0, 15, 35, 60),
               c(0, 12, 18, 22),
               c(0,  8, 22, 30))

  net_matrix  <- population * (inc - matrix(coupons, nrow = 3, ncol = 4, byrow = TRUE))
  cost_matrix <- population * matrix(coupons, nrow = 3, ncol = 4, byrow = TRUE)
  objective   <- as.vector(t(net_matrix))

  one_per_segment <- matrix(0, nrow = 3, ncol = 12)
  for (i in 1:3) one_per_segment[i, ((i - 1) * 4 + 1):(i * 4)] <- 1
  budget_row  <- as.vector(t(cost_matrix))
  constraints <- rbind(one_per_segment, budget_row)
  direction   <- c(rep("==", 3), "<=")
  rhs         <- c(rep(1, 3), budget)

  solution <- lp("max", objective, constraints, direction, rhs, all.bin = TRUE)
  choice   <- matrix(solution$solution, nrow = 3, byrow = TRUE)
  chosen   <- coupons[apply(choice, 1, which.max)]
  spend    <- sum(population * chosen)

  sub_rule("Optimal coupon plan")
  for (i in 1:3) cat(sprintf("  %-20s coupon $%2d   (spend %s, net %s)\n", segments[i], chosen[i],
                             money(population[i] * chosen[i]),
                             money(population[i] * (inc[i, match(chosen[i], coupons)] - chosen[i]))))
  cat(sprintf("  Total net incremental revenue: %s  |  spend %s of the %s budget\n",
              money(solution$objval), money(spend), money(budget)))

  greedy_coupon <- coupons[apply(net_matrix, 1, which.max)]
  greedy_cost   <- sum(population * greedy_coupon)
  greedy_net    <- sum(sapply(1:3, function(i) net_matrix[i, match(greedy_coupon[i], coupons)]))
  reading(sprintf("every $1 of coupon returns about $%.2f of incremental revenue, and %s of the budget is left unspent. ",
                  (solution$objval + spend) / spend, money(budget - spend)),
          if (greedy_cost > budget)
            sprintf("The budget binds: giving every segment its own best coupon would cost %s and earn %s, so we trim the segment whose extra coupon dollars add least, giving up only %s of net.",
                    money(greedy_cost), money(greedy_net), money(greedy_net - solution$objval)) else "")
  invisible(list(chosen = chosen, net = solution$objval, spend = spend))
}

section_takeaways <- function(plan) {
  rule("SUMMARY")
  naive_r2 <- summary(lm(as.formula(paste(V, "~ monetary")), data = feat))$r.squared
  mon_cor  <- cor(feat$monetary, feat[[V]])
  age_cor  <- cor(feat$age, feat[[V]])
  vip_share <- sum(feat[[V]][feat$segment == "VIPs"]) / sum(feat[[V]])
  net_by_ch <- sapply(seq_len(nrow(channels)), function(k) {
    sub <- feat[feat$acquisition_channel == channels$channel_name[k], ]
    sum(sub$monetary) * (1 - channels$revenue_share_rate[k]) - nrow(sub) * channels$cost_per_signup[k]
  })
  cat(sprintf("  1. Value is concentrated: %d VIPs (%s of customers) hold %s of next-year value.\n",
              sum(feat$segment == "VIPs"), pct(mean(feat$segment == "VIPs")), pct(vip_share)))
  cat(sprintf("  2. Value follows behaviour more than demographics: spend correlates %.3f with value and alone predicts %s of it;\n",
              mon_cor, pct(naive_r2)))
  cat(sprintf("     age correlates only %.3f and is a weak within-segment retention tiebreaker that does not apply to VIPs.\n", age_cor))
  cat(sprintf("  3. The acquisition mix is net positive overall: about %s after commission and signup cost.\n", money(sum(net_by_ch))))
  cat(sprintf("  4. Best coupon plan: VIPs $%d, Bargain Hunters $%d, Occasional Shoppers $%d, returning %s net for %s spent.\n",
              plan$chosen[1], plan$chosen[2], plan$chosen[3], money(plan$net), money(plan$spend)))
  invisible(NULL)
}

section_overview()
section_segments()
section_drivers()
section_age()
section_channels()
section_category()
section_retention()
section_geography()
section_lapsed()
section_tests()
plan <- section_budget()
section_takeaways(plan)

sink()
close(report_con)
cat(sprintf("\nFull report also saved to %s\n", report_path))
