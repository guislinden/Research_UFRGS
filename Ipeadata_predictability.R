#############################################################
## Here we gather de results from the models
## gslindenmeyer@gmail.com - Nov 2021
##
## -based on H. Kauppi and T. Virtanen code
#############################################################

##############################
# 0 - Load libraries
##############################
rm(list = ls())
set.seed(123)

require(mboost)
require(R.matlab)
require(forecast)
require(sandwich)
#data <- readMat("FRED.mat")
source("helper_functions_analysis.R")

##############
## Settings ##
##############
## Dataset

load("data/dataset.RData")
dataset$na_2019 = append(dataset$na_2019,c(31,54,126)) # remendo

# Division of train/test
train_startyear <- 1996 # 1996
test_startyear <- 2014 # Def=1999

# We do estimation by rounds. Roughly round = test_years / 12 and blocksize is 12
estimation_rounds <- 6
test_blocksize <- 12

# Minimum number of valid observations required for estimation
min_obs_required <- 50 # Def=50

# do we want to do these regressions?
do_bols <- 1
do_blackboost <- 1


#  data set
yt_data <- dataset$data
#yt_data1 <- data$d.values


# PARAMETERS
predlags <- 12
araic_maxlags <- 12
boost_maxlags <- 12
mstop <- 300
hmax <- 12 # Def=12
hrange <- c(1:hmax) # Def=1:12
deg_freedom <- 4 # Def=4
cv_folds <- 5 # Def=5
boost_use_lags <- "FULL" # "FULL" for all 12 or "BIC" for same as with AR(BIC)
maxlearners <- mstop # Def 300
bols_maxlearners <- mstop # Def 300
spline_bctrl <- boost_control(mstop = maxlearners)
bols_bctrl <- boost_control(mstop = bols_maxlearners)


save_directory <- paste("IPEAtests2", mstop, "/", sep = "") # Add / to end or leave empty!


# Preparations
fileid <- sprintf("%s_%s_%s_%d_%d_%d", "IPEA", "recursive", "stationary", train_startyear, test_startyear, (estimation_rounds * test_blocksize))

# Singleton dimensions will be collapsed, so..
if (estimation_rounds == 1) {
  store_all_insamples <- 0
  store_all_partials <- 0
}

# Which series to forecast
#series <- c(1:47)
#series <- c(48:95)
series <- c(92:95)
##############
## The loop ##
##############
loop_continue <- 1

ts <- series[1]
series <- series[-1]

while (loop_continue) {
  t0 <- Sys.time()
  if (ts %in% dataset$na_2019) {
    test_rounds <- estimation_rounds - 1
  } else {
    test_rounds <- estimation_rounds
  }

  # Create the overall data frame
  # ts_data1<-data_to_frame_multistep(yt_data1[,ts],predlags,hmax,data$d.year,data$d.month, data$d.transform[,ts])
  ts_data <- data_to_frame_multistep(yt_data[, ts], predlags, hmax, dataset$year, dataset$month, dataset$transformation[, ts])

  # Find the initial training and test data start and end indexes
  # ts_len=nrow(data$d.values)
  train_startidx <- min(which(ts_data$Year %in% c(train_startyear)))
  train_endidx <- max(which(ts_data$Year %in% c(test_startyear - 1)))
  test_startidx <- min(which(ts_data$Year %in% c(test_startyear)))

  # m0: NULL const, alternative boosting
  # m1: NULL AR(p), alternative boosting
  # m2: NULL AR(p), alternative AR(p)+boosting

  # Space for storing the learner counts
  bspline_learners <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  bspline_learners_aic <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  
  # Const prediction for each horizon
  const_pred <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)

  # AR(BIC) prediction and lags
  bic_pred <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  bic_lags <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)

  # Two-stage boosting
  tsboost_pred <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  tsboost_learners <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  
  tsboost_pred_aic <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  tsboost_learners_aic <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  # OLS Boosting
  bols_learners <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  bols_learners_aic <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  
  # Tree Boosting
  tree_learners <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  tree_learners_aic <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  
  # No extrapolation prediction
  bspline_noextra_pred <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  bspline_noextra_repl <- matrix(data = 0, ncol = nrow(ts_data), nrow = hmax)
  tsboost_noextra_pred <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  tsboost_noextra_repl <- matrix(data = 0, ncol = nrow(ts_data), nrow = hmax)

  bspline_noextra_pred_aic <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  bspline_noextra_repl_aic <- matrix(data = 0, ncol = nrow(ts_data), nrow = hmax)
  tsboost_noextra_pred_aic <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  tsboost_noextra_repl_aic <- matrix(data = 0, ncol = nrow(ts_data), nrow = hmax)
  
  # In-sample fitted values CHECK
  # if (store_all_insamples == 1) {
  #   ar_insample_fits <- array(data = NaN, dim = c(test_rounds, hmax, nrow(ts_data)))
  #   bic_insample_fits <- array(data = NaN, dim = c(test_rounds, hmax, nrow(ts_data)))
  #   bspline_insample_fits <- array(data = NaN, dim = c(test_rounds, hmax, nrow(ts_data)))
  #   tsboost_insample_fits <- array(data = NaN, dim = c(test_rounds, hmax, nrow(ts_data)))
  # } else {
  ar_insample_fits <- array(data = NaN, dim = c(hmax, nrow(ts_data)))
  bic_insample_fits <- matrix(data = NaN, ncol = nrow(ts_data), nrow = hmax)
  bspline_insample_fits <- array(data = NaN, dim = c(hmax, nrow(ts_data)))
  tsboost_insample_fits <- array(data = NaN, dim = c(hmax, nrow(ts_data)))
  # }

  # Pointers for estimation rounds
  train_data_start <- mat.or.vec(test_rounds, 1)
  train_data_end <- mat.or.vec(test_rounds, 1)
  test_data_start <- mat.or.vec(test_rounds, 1)
  test_data_end <- mat.or.vec(test_rounds, 1)

  cat("\nTIME SERIES:", paste0(dataset$metadados$code[ts]), " ( Index: ", ts, ") ", train_startyear, " ( Max Learners: ", maxlearners, ")\n")
  pb <- txtProgressBar(min = 0, max = test_rounds * length(hrange), style = 3)
  pbDone <- 0
  setTxtProgressBar(pb, pbDone)


  for (tround in 0:(test_rounds - 1)) {


    # This points to the current y_t
    yt_idx <- test_startidx + tround * test_blocksize

    for (h in hrange) {
      # Name of the variable that we are trying to predict
      predicted_name <- paste0("Ytp", h)

      # Calculate indexes where training and test data starts and ends
      train_start <- train_startidx
      train_end <- yt_idx - h # We cannot use more data in estimation than up to yt_idx
      test_start <- yt_idx
      test_end <- yt_idx + test_blocksize - 1

      # Remove NaN observations from the beginning (if any)
      maxlagname <- paste0("Ytm", (predlags - 1))
      while (is.na(ts_data[train_start, maxlagname]) && train_start < train_end) {
        train_start <- train_start + 1
      }

      # Store the pointers for this round
      train_data_start[tround + 1] <- train_startidx
      train_data_end[tround + 1] <- yt_idx - 1
      test_data_start[tround + 1] <- yt_idx
      test_data_end[tround + 1] <- yt_idx + test_blocksize - 1

      # Mean, min and max values
      mu <- mean(ts_data[train_start:train_end, predicted_name])
      maxval <- max(max(ts_data[train_start:train_end, "Ytm11"]), max(ts_data[train_start:train_end, "Ytm0"]))
      minval <- min(min(ts_data[train_start:train_end, "Ytm11"]), min(ts_data[train_start:train_end, "Ytm0"]))

      # Const model
      const_pred[h, test_start:test_end] <- mu

      # Fit AR(AIC)
      llist <- empirical_linfit_aic_h(ts_data[train_start:train_end, ], araic_maxlags, h)
      lmodel <- llist$model
      ar_pred_name <- paste0("ar_pred_Ytp", h)
      ar_lags_name <- paste0("ar_lags_Ytp", h)
      ts_data[test_start:test_end, ar_pred_name] <- predict(lmodel, ts_data[test_start:test_end, ])
      ts_data[test_start:test_end, ar_lags_name] <- llist$lags
      AIC_lags <- llist$lags

      # Fit AR(BIC)
      llist <- empirical_linfit_bic_h(ts_data[train_start:train_end, ], araic_maxlags, h)
      biclmodel <- llist$model
      bic_pred[h, test_start:test_end] <- predict(biclmodel, ts_data[test_start:test_end, ])
      bic_lags[h, test_start:test_end] <- llist$lags
      BIC_lags <- llist$lags

      if (boost_use_lags == "FULL") {
        boostmodel_lags <- boost_maxlags
      } else {
        boostmodel_lags <- BIC_lags
        if (boostmodel_lags == 0) {
          boostmodel_lags <- 1
        }
      }

      # Boost spline
      bbsmodel <- empirical_boost_spline_h(ts_data[train_start:train_end, ], boostmodel_lags, spline_bctrl, deg_freedom, h)
      cvr <- cross_validate_2(bbsmodel, cv_folds)
      learners <- mstop(cvr)
      learnersaic <- mstop(AIC(bbsmodel))
      learnersaic <- ifelse(length(learnersaic)>0, learnersaic,0)
      
      bspline_pred_name <- paste0("bspline_pred_Ytp", h)
      bspline_learners[h, test_start:test_end] <- learners
      
      
      options(warn = 1)
      for (value in test_start:test_end) {
        ts_data[value, bspline_pred_name] <- predict(bbsmodel[learners], ts_data[value, ])
        
        result <- tryCatch(predict(bbsmodel[learners], ts_data[value, ]),
          error = function(e) e,
          warning = function(w) w
        )
        if (inherits(result, "warning")) { # or !is.null(warnings())
          bspline_noextra_pred[h, ][value] <- bic_pred[h, value]
          bspline_noextra_repl[h, ][value] <- 1
        } else {
          bspline_noextra_pred[h, ][value] <- ts_data[value, bspline_pred_name]
        }
      }

      bspline_pred_name <- paste0("bspline_pred_aic_Ytp", h)
      bspline_learners_aic[h, test_start:test_end] <- learnersaic
      
      for (value in test_start:test_end) {
        ts_data[value, bspline_pred_name] <- predict(bbsmodel[learnersaic], ts_data[value, ])
        
        result <- tryCatch(predict(bbsmodel[learnersaic], ts_data[value, ]),
                           error = function(e) e,
                           warning = function(w) w
        )
        if (inherits(result, "warning")) { # or !is.null(warnings())
          bspline_noextra_pred_aic[h, ][value] <- bic_pred[h, value]
          bspline_noextra_repl_aic[h, ][value] <- 1
        } else {
          bspline_noextra_pred_aic[h, ][value] <- ts_data[value, bspline_pred_name]
        }
      }
      


      # Boost spline to the AR(BIC) residuals
      ts_data[train_start:train_end, "BIC_residual"] <- ts_data[train_start:train_end, predicted_name] - biclmodel$fitted.values
      tsmodel <- empirical_boost_residuals(ts_data[train_start:train_end, ], boostmodel_lags, spline_bctrl, deg_freedom)
      cvr <- cross_validate_2(tsmodel, cv_folds)
      learners <- mstop(cvr)
      # learners <- mstop(AIC(tsmodel))
      tsboost_learners[h, test_start:test_end] <- learners


      for (value in test_start:test_end) {
        tsboost_pred[h, value] <- bic_pred[h, value] + predict(tsmodel[learners], ts_data[value, ])

        result <- tryCatch(predict(tsmodel[learners], ts_data[value, ]),
          error = function(e) e,
          warning = function(w) w
        )
        if (inherits(result, "warning")) { # or !is.null(warnings())
          tsboost_noextra_pred[h, ][value] <- bic_pred[h, value]
          tsboost_noextra_repl[h, ][value] <- 1
        } else {
          tsboost_noextra_pred[h, ][value] <- tsboost_pred[h, value]
        }
      }

      learnersaic <- mstop(AIC(tsmodel))
      learnersaic <- ifelse(length(learnersaic)>0, learnersaic,0)
      tsboost_learners_aic[h, test_start:test_end] <-  learnersaic
      
      for (value in test_start:test_end) {
        tsboost_pred_aic[h, value] <- bic_pred[h, value] + predict(tsmodel[learnersaic], ts_data[value, ])
        
        result <- tryCatch(predict(tsmodel[learnersaic], ts_data[value, ]),
                           error = function(e) e,
                           warning = function(w) w
        )
        if (inherits(result, "warning")) { # or !is.null(warnings())
          tsboost_noextra_pred_aic[h, ][value] <- bic_pred[h, value]
          tsboost_noextra_repl_aic[h, ][value] <- 1
        } else {
          tsboost_noextra_pred_aic[h, ][value] <- tsboost_pred_aic[h, value]
        }
      }
      

      # Boost OLS
      if (do_bols) {
        bolsmodel <- empirical_boost_ols_h(ts_data[train_start:train_end, ], boostmodel_lags, bols_bctrl, h)
        cvr <- cross_validate_2(bolsmodel, cv_folds)
        blstop <- mstop(cvr)
        blstopaic <- mstop(AIC(bolsmodel))
        blstopaic = ifelse(length(learnersaic)>0, blstopaic,0)
        bols_pred_name <- paste0("bols_pred_Ytp", h)
        ts_data[test_start:test_end, bols_pred_name] <- predict(bolsmodel[blstop], ts_data[test_start:test_end, ])
        
        bols_pred_name <- paste0("bols_pred_aic_Ytp", h)
        ts_data[test_start:test_end, bols_pred_name] <- predict(bolsmodel[blstopaic], ts_data[test_start:test_end, ])
        
        
        bols_learners[h, test_start:test_end] <- blstop
        bols_learners_aic[h, test_start:test_end] <-  blstopaic
        
      }

      # Blacktree

      if (do_blackboost) {
        treemodel <- empirical_boost_tree_h(trdata = ts_data[train_start:train_end, ], maxlags = boostmodel_lags, bctrl = bols_bctrl, h = h)
        treemodel2 <- empirical_boost_tree_h2(trdata = ts_data[train_start:train_end, ], maxlags = boostmodel_lags, bctrl = bols_bctrl, h = h)
        cvr <- cross_validate_2(treemodel, cv_folds)
        cvr2 <- cross_validate_2(treemodel2, cv_folds)
        
        treestop <- mstop(cvr)
        treestop2 <- mstop(cvr2)
        
        tree_pred_name <- paste0("tree_pred_Ytp", h)
        ts_data[test_start:test_end, tree_pred_name] <- predict(treemodel[treestop], ts_data[test_start:test_end, ])
        
        tree_pred_name <- paste0("tree_pred_aic_Ytp", h)
        ts_data[test_start:test_end, tree_pred_name] <- predict(treemodel[treestop2], ts_data[test_start:test_end, ])
        
        # tree_pred_name <- paste0("tree_pred_aic_Ytp", h)
        # ts_data[test_start:test_end, tree_pred_name] <- predict(treemodel[treestopaic], ts_data[test_start:test_end, ])
        # 
        # 
        # tree_learners_aic[h, test_start:test_end] <- treestop
      }

      # # Store in-sample values (all or just first model depending on flag)
      # if (store_all_insamples) {
      #   ar_insample_fits[(tround + 1), h, train_start:train_end] <- lmodel$fitted.values
      #   bspline_insample_fits[(tround + 1), h, train_start:train_end] <- bbsmodel$fitted()
      #   tsboost_insample_fits[(tround + 1), h, train_start:train_end] <- tsmodel$fitted()
      #   bic_insample_fits[(tround + 1), h, train_start:train_end] <- biclmodel$fitted.values
      # } else {
      if (tround == 0) {
        ar_insample_fits[h, train_start:train_end] <- lmodel$fitted.values
        bspline_insample_fits[h, train_start:train_end] <- bbsmodel$fitted()
        tsboost_insample_fits[h, train_start:train_end] <- tsmodel$fitted()
        bic_insample_fits[h, train_start:train_end] <- biclmodel$fitted.values
      }
      # }

      pbDone <- pbDone + 1
      setTxtProgressBar(pb, pbDone)
    }
  }

  train_start_str <- sprintf("01.%02d.%02d", ts_data$Month[train_start], ts_data$Year[train_start])
  test_start_str <- sprintf("01.%02d.%02d", ts_data$Month[test_startidx], ts_data$Year[test_startidx])

  # Make matrixes out of the prediction variables
  ar_pred <- matrix(ncol = nrow(ts_data), nrow = hmax)
  ar_lags <- matrix(ncol = nrow(ts_data), nrow = hmax)
  bspline_pred <- matrix(ncol = nrow(ts_data), nrow = hmax)
  bols_pred <- matrix(ncol = nrow(ts_data), nrow = hmax)
  tree_pred <- matrix(ncol = nrow(ts_data), nrow = hmax)
  
  bspline_pred_aic <- matrix(ncol = nrow(ts_data), nrow = hmax)
  bols_pred_aic <- matrix(ncol = nrow(ts_data), nrow = hmax)
  tree_pred_aic <- matrix(ncol = nrow(ts_data), nrow = hmax)
  
  true_Ytph <- matrix(ncol = nrow(ts_data), nrow = hmax)

  for (hh in hrange) {
    ar_pred_name <- paste0("ar_pred_Ytp", hh)
    ar_lags_name <- paste0("ar_lags_Ytp", hh)
    ar_is_name <- paste0("ar_is_Ytp", hh)
    bspline_pred_name <- paste0("bspline_pred_Ytp", hh)
    bspline_is_name <- paste0("bspline_is_Ytp", hh)
    bols_pred_name <- paste0("bols_pred_Ytp", hh)
    tree_pred_name <- paste0("tree_pred_Ytp", hh)
    
    bspline_pred_aic_name <- paste0("bspline_pred_aic_Ytp", hh)
    bols_pred_aic_name <- paste0("bols_pred_aic_Ytp", hh)
    tree_pred_aic_name <- paste0("tree_pred_aic_Ytp", hh)
    
    Ytph_name <- paste0("Ytp", hh)
    
    ar_pred[hh, ] <- t(ts_data[, ar_pred_name])
    ar_lags[hh, ] <- t(ts_data[, ar_lags_name])
    bols_pred[hh, ] <- t(ts_data[, bols_pred_name])
    tree_pred[hh, ] <- t(ts_data[, tree_pred_name])
    bspline_pred[hh, ] <- t(ts_data[, bspline_pred_name])
    
    bols_pred_aic[hh, ] <- t(ts_data[, bols_pred_aic_name])
    tree_pred_aic[hh, ] <- t(ts_data[, tree_pred_aic_name])
    bspline_pred_aic[hh, ] <- t(ts_data[, bspline_pred_aic_name])
    
    true_Ytph[hh, ] <- ts_data[, Ytph_name]
  }

  filename <- sprintf("%s%s_%d(%s).mat", save_directory, fileid, ts, dataset$metadados$code[ts])
  writeMat(filename,
    varname = dataset$metadados$code[ts],
    vartitle = dataset$metadados$name[ts],
    transformation = dataset$transformation[, ts],
    theme = as.character(dataset$metadados$sname[ts]),
    
    year = ts_data$Year,
    month = ts_data$Month,
    
    true_yt = ts_data$Ytm0,
    Xt = ts_data$Xt,
    true_Ytph = true_Ytph,
    const_pred = const_pred,
    
    ar_pred = ar_pred,
    ar_lags = ar_lags,
    ar_insample_fits = ar_insample_fits,
    
    bic_pred = bic_pred,
    bic_lags = bic_lags,
    bic_insample_fits = bic_insample_fits,
    
    bspline_pred = bspline_pred,
    bspline_learners = bspline_learners,
    bspline_insample_fits = bspline_insample_fits,
    
    bspline_pred_aic = bspline_pred_aic,
    bspline_learners_aic = bspline_learners_aic,
    
    
    bspline_noextra_pred = bspline_noextra_pred,
    bspline_noextra_repl = bspline_noextra_repl,
    
    bspline_noextra_pred_aic = bspline_noextra_pred_aic,
    bspline_noextra_repl_aic = bspline_noextra_repl_aic,
    
    bols_pred = bols_pred,
    bols_learners = bols_learners,
    
    bols_pred_aic = bols_pred_aic,
    bols_learners_aic = bols_learners_aic,
    
    
    tree_pred = tree_pred,
    tree_learners = tree_learners,
    
    tree2_pred = tree_pred_aic,
    tree2_learners = tree_learners_aic,
    
    
    tsboost_learners = tsboost_learners,
    tsboost_pred = tsboost_pred,
    tsboost_learners_aic = tsboost_learners_aic,
    tsboost_pred_aic = tsboost_pred_aic,
    
    tsboost_insample_fits = tsboost_insample_fits,
    
    tsboost_noextra_pred = tsboost_noextra_pred,
    tsboost_noextra_repl = tsboost_noextra_repl,
    tsboost_noextra_pred_aic = tsboost_noextra_pred_aic,
    tsboost_noextra_repl_aic = tsboost_noextra_repl_aic,
    
    
    s_test_blocksize = test_blocksize,
    s_all_insamples = 0,
    s_all_partials = 0,
    s_deg_freedom = deg_freedom,
    s_train_startyear = train_startyear,
    s_test_startyear = test_startyear,
    s_predlags = predlags,
    s_boost_maxlags = boost_maxlags,
    s_araic_maxlags = araic_maxlags,
    s_hmax = hmax,
    s_cv_folds = cv_folds,
    s_true_test_start = test_start_str,
    s_true_train_start = train_start_str,
    s_test_rounds = test_rounds,
    s_included_bols = do_bols,
    train_data_start = train_data_start,
    train_data_end = train_data_end,
    test_data_start = test_data_start,
    test_data_end = test_data_end
  )
  ################################
  # Get the next series or stop. #
  ################################
  t1 <- Sys.time()
  print(t1 - t0)

  if (length(series) > 0) {
    ts <- series[1]
    series <- series[-1]
  } else {
    loop_continue <- 0
  }
}


dale <- readMat("others/FREDTests/FRED_MSW_recursive_stationary_1959_1999_204_1(RPI).mat")
dale <- readMat("IPEAtests5/IPEA_recursive_stationary_1996_2014_72_140(SRF12_ITR12).mat")
### Analysis
filenames <- list.files("IPEAtests/")[11]
data_test <- readMat(paste("IPEAtests/", filenames, sep = ""))

tl <- 480:600
h <- 1
plot.ts(data_test$Xt[tl])
lines(level$bic_pred[h, tl], col = "purple")
lines(level$bspline_pred[h, tl], col = "red")
lines(level$tsboost_pred[h, tl], col = "blue")
lines(level$bols_pred[h, tl], col = "green")
lines(level$tree_pred[h, tl], col = "brown")


plot.ts(data_test$true.Ytph[h, ][tl - h])
lines(data_test$bic.pred[h, tl], col = "purple")
lines(data_test$bspline.pred[h, tl], col = "red")
lines(data_test$tsboost.pred[h, tl], col = "blue")
lines(data_test$bols.pred[h, tl], col = "green")
lines(data_test$tree.pred[h, tl], col = "brown")



real_data <- data_test$Xt

level <- back_to_level(data_test) # ,transform = 5)

BIC_test <- back_to_level(data_test$bic.pred[1, ], real_data)
bols_test <- back_to_level(data_test$bols.pred[1, ], real_data)
ts_test <- back_to_level(data_test$tsboost.pred[1, ], real_data)
bsplines_test <- back_to_level(data_test$bspline.pred[1, ], real_data)

mse(level$const_pred[1, ], real_data)
mse(level$bic_pred[1, ], real_data)
mse(level$bols_pred[1, ], real_data)
mse(level$bspline_pred[1, ], real_data)
mse(level$tsboost_pred[1, ], real_data)
mse(level$tree_pred[1, ], real_data)

r_vector <- c()
r_vector2 <- c()
for (i in 1:12) {
  # r_vector = c(r_vector,r_squared(level$bic_pred[i,], real_data))
  # r_vector2 = c(r_vector2,r_squared(level$tsboost_pred[i,], real_data))
  r_vector <- c(r_vector, r_squared(data_test$bic.pred[i, ], data_test$true.Ytph[i, ]))
  r_vector2 <- c(r_vector2, r_squared(data_test$bspline.pred[i, ], data_test$true.Ytph[i, ]))
}


