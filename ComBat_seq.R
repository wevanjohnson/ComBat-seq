#' Adjust for batch effects using an empirical Bayes framework in RNA-seq raw counts
#' 
#' ComBat_seq is an extension to the ComBat method using Negative Binomial model.
#' 
#' @param counts Raw count matrix from genomic studies (dimensions gene x sample) 
#' @param batch Batch covariate (only one batch allowed)
#' @param mod Model matrix for outcome of interest and other covariates besides batch
#' 
#' @return data A probe x sample count matrix, adjusted for batch effects.
#' 
#' @examples 

#'
#' @export
#' 

ComBat_seq <- function(counts, batch, group, full_mod=TRUE){
  ########  Preparation  ########  
  library(edgeR)  # require bioconductor 3.7, edgeR 3.22.1, otherwise run  # source("glmfit.R")
  dge_obj <- DGEList(counts=counts, group=group)
  
  ## Prepare characteristics on batches
  batch <- as.factor(batch)
  n_batch <- nlevels(batch)  # number of batches
  batches_ind <- lapply(1:n_batch, function(i){which(batch==levels(batch)[i])}) # list of samples in each batch  
  n_batches <- sapply(batches_ind, length)
  #if(any(n_batches==1)){mean_only=TRUE; cat("Note: one batch has only one sample, setting mean.only=TRUE\n")}
  n_sample <- sum(n_batches)
  cat("Found",n_batch,'batches\n')
  
  ## Make design matrix 
  # batch
  batchmod <- model.matrix(~-1+batch)  # colnames: levels(batch)
  # covariate
  group <- as.factor(group)
  if(full_mod){
    mod <- model.matrix(~group)
  }else{
    mod <- model.matrix(~1, data=as.data.frame(t(counts)))
  }
  # combine
  design <- cbind(batchmod, mod)
  
  ## Check for intercept in covariates, and drop if present
  check <- apply(design, 2, function(x) all(x == 1))
  #if(!is.null(ref)){check[ref]=FALSE} ## except don't throw away the reference batch indicator
  design <- as.matrix(design[,!check])
  cat("Adjusting for",ncol(design)-ncol(batchmod),'covariate(s) or covariate level(s)\n')
  
  ## Check if the design is confounded
  if(qr(design)$rank<ncol(design)){
    #if(ncol(design)<=(n_batch)){stop("Batch variables are redundant! Remove one or more of the batch variables so they are no longer confounded")}
    if(ncol(design)==(n_batch+1)){stop("The covariate is confounded with batch! Remove the covariate and rerun ComBat")}
    if(ncol(design)>(n_batch+1)){
      if((qr(design[,-c(1:n_batch)])$rank<ncol(design[,-c(1:n_batch)]))){stop('The covariates are confounded! Please remove one or more of the covariates so the design is not confounded')
      }else{stop("At least one covariate is confounded with batch! Please remove confounded covariates and rerun ComBat")}}
  }

  ## Check for missing values in count matrix
  NAs = any(is.na(counts))
  if(NAs){cat(c('Found',sum(is.na(counts)),'Missing Data Values\n'),sep=' ')}

  
  ########  Estimate gene-wise dispersions within each batch  ########
  ## Estimate common dispersion within each batch as an initial value
  disp_common <- sapply(1:n_batch, function(i){
    if(n_batches[i]==1){
      stop("Not supporting 1 sample per batch yet!")
    }else if(n_batches[i] <= ncol(design)-ncol(batchmod)+1){ 
      # not enough residual degree of freedom
      return(estimateGLMCommonDisp(counts[, batches_ind[[i]]], design=NULL, subset=nrow(counts)))
      #as.matrix(design[batches_ind[[i]], (n_batch+1):ncol(design)]),
    }else{
      return(estimateGLMCommonDisp(counts[, batches_ind[[i]]], design=mod[batches_ind[[i]], ], subset=nrow(counts)))
    }
  })
  
  ## Estimate gene-wise dispersion within each batch 
  genewise_disp_lst <- lapply(1:n_batch, function(j){
    if(n_batches[j]==1){
      stop("Not supporting 1 sample per batch yet!")
    }else if(n_batches[j] <= ncol(design)-ncol(batchmod)+1){
      # not enough residual degrees of freedom
      # return(estimateGLMTagwiseDisp(counts[, batches_ind[[j]]], design=NULL, 
      #                               dispersion=disp_common[j], prior.df=0))
      return(rep(disp_common[j], nrow(counts)))
      #as.matrix(design[batches_ind[[j]], (n_batch+1):ncol(design)]),
    }else{
      return(estimateGLMTagwiseDisp(counts[, batches_ind[[j]]], design=mod[batches_ind[[j]], ], 
                                    dispersion=disp_common[j], prior.df=0))
    }
  })
  names(genewise_disp_lst) <- paste0('batch', levels(batch))
  
  ## construct dispersion matrix
  phi_matrix <- matrix(NA, nrow=nrow(counts), ncol=ncol(counts))
  for(k in 1:n_batch){
    phi_matrix[, batches_ind[[k]]] <- vec2mat(genewise_disp_lst[[k]], n_batches[k]) #matrix(rep(genewise_disp_lst[[k]], n_batches[k]), ncol=n_batches[k])
  }#round(apply(phi_matrix,2,mean),2)
  
    
  ########  Estimate parameters from NB GLM  ########
  glm_f <- glmFit.DGEList(dge_obj, design=design, dispersion=phi_matrix) #no intercept - nonEstimable; compute offset (library sizes) within function
  alpha_g <- glm_f$coefficients[, 1:n_batch] %*% as.matrix(n_batches/n_sample) #compute intercept as batch-size-weighted average from batches
  new_offset <- t(vec2mat(getOffset(dge_obj), nrow(counts))) +   # original offset - sample (library) size
    vec2mat(alpha_g, ncol(counts))  # new offset - gene background expression
  # getOffset(dge_obj) is the same as log(dge_obj$samples$lib.size)
  glm_f2 <- glmFit.default(dge_obj$counts, design=design, dispersion=phi_matrix, 
                           offset=new_offset, prior.count=0) 
  
  beta_hat <- glm_f2$coefficients[, (n_batch+1):ncol(design)]
  gamma_hat <- glm_f2$coefficients[, 1:n_batch]
  mu_hat <- glm_f2$fitted.values
  phi_hat <- do.call(cbind, genewise_disp_lst)
  #if(!identical(colnames(gamma_hat), colnames(phi_hat))){stop("gamma and phi don't match!")}
  #tmp = mu_hat - exp(glm_f2$coefficients %*% t(design) + new_offset); tmp[1:6,1:6]; mean(tmp)
  
  
  ########  In each batch, compute posterior estimation through Monte-Carlo integration  ########  
  monte_carlo_res <- lapply(1:n_batch, function(ii){
    monte_carlo_int_NB(dat=counts[, batches_ind[[ii]]], mu=mu_hat[, batches_ind[[ii]]], 
                       gamma=gamma_hat[, ii], phi=phi_hat[, ii])
    #dat=counts[, batches_ind[[ii]]]; mu=mu_hat[, batches_ind[[ii]]]; gamma=gamma_hat[, ii]; phi=phi_hat[, ii]
  })
  names(monte_carlo_res) <- paste0('batch', levels(batch))
  
  gamma_star_mat <- lapply(monte_carlo_res, function(res){res$gamma_star})
  gamma_star_mat <- do.call(cbind, gamma_star_mat)
  phi_star_mat <- lapply(monte_carlo_res, function(res){res$phi_star})
  phi_star_mat <- do.call(cbind, phi_star_mat)
  
  
  ########  Obtain adjusted batch-free distribution  ########
  mu_star <- matrix(NA, nrow=nrow(counts), ncol=ncol(counts))
  for(jj in 1:n_batch){
    mu_star[, batches_ind[[jj]]] <- exp(log(mu_hat[, batches_ind[[jj]]])-
                                          vec2mat(gamma_star_mat[, jj], n_batches[jj])#-
                                          #t(vec2mat(getOffset(dge_obj)[batches_ind[[jj]]], nrow(counts)))
    )
  }
  phi_star <- rowMeans(phi_star_mat)
  
  
  ########  Adjust the data  ########  
  adjust_counts <- matrix(NA, nrow=nrow(counts), ncol=ncol(counts))
  for(kk in 1:n_batch){
    counts_sub <- counts[, batches_ind[[kk]]]
    old_mu <- mu_hat[, batches_ind[[kk]]]
    old_phi <- phi_hat[, kk]
    new_mu <- mu_star[, batches_ind[[kk]]]
    new_phi <- phi_star
    adjust_counts[, batches_ind[[kk]]] <- match_quantiles(counts_sub=counts_sub, 
                                                          old_mu=old_mu, old_phi=old_phi, 
                                                          new_mu=new_mu, new_phi=new_phi)
  }
  
  return(adjust_counts)
}