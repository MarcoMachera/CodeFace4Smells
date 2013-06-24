library(zoo)
library(xts)
source("../prosoda/db.r")

gen.forest <- function(conf, repo.path, resdir) {
  ## TODO: Use apt ML specific preprocessing functions, not always the
  ## lkml variant
  corp.file <- file.path(resdir, "corp.base")
  doCompute <- !(file.exists(corp.file))

  if (doCompute) {
    corp.base <- gen.corpus(conf$ml, repo.path, suffix=".mbox",
                            marks=c("^_{10,}", "^-{10,}", "^[*]{10,},",
                                   # Also remove inline diffs. TODO: Better
                                   # heuristics for non-git projects
                                   "^diff --git", "^@@",
                                   "^The following changes since commit",
                                   # Generic majordomo? (note that "--" is
                                   # often used instead of "-- "
                                   "^--$", "^---$", "^To unsubscribe",
                                   # The following are specific for Linux kernel
                                   # style projects
                                   "^Signed-off-by", "^Acked-by", "CC:"),
                              encoding="UTF-8",
                              preprocess=linux.kernel.preprocess)
    save(file=corp.file, corp.base)
  } else {
    load(file=corp.file)
  }

  return(corp.base)
}


compute.doc.matrices <- function(forest.corp, data.path) {
  ## NOTE: Stemming seems to have some encoding problem with UTF-8.
  ## And it takes some amount of time: About one hour for 10000 documents.
  ## TODO: Let this run in parallel (is this already supported by the MPI
  ## methods of package tm?)
  
  ## TODO: Should we set the minimal wordlength to something larger than 3?
  ## (see ?termFreq for possible options)
  tdm.file <- file.path(data.path, "tdm")
  dtm.file <- file.path(data.path, "dtm")

  doCompute <- !(file.exists(tdm.file)) && !(file.exists(dtm.file))

  if (doCompute) {
    ## TODO: Any arguments against creating dtm as transpose of tdm?
    tdm <- TermDocumentMatrix(forest.corp$corp,
                              list(stemming = FALSE, stopwords = FALSE))
    dtm <- DocumentTermMatrix(forest.corp$corp,
                              list(stemming = FALSE, stopwords = FALSE))
    ## Oookay, this is just for the linguistically curious: Check how well
    ## Zipf's and Heap's law are fulfilled.
###Zipf_plot(dtm)
###Heaps_plot(dtm)
###plot(tdm) # Pointless without a restriction to frequent keywords

    ## NOTE: Computing the dissimilarity matrix is computationally expensive
###diss <- dissimilarity(tdm, method = "cosine")
####test.hclust <- hclust(diss)
    ## TODO: Once we have the dissimilarity matrix, we can apply all the
    ## standard clustering techniques. The results will need to be interpreted,
    ## though. For instance, use hclust. Albeit this is fairly pointless by
    ## now -- we need to find some criteria to cluster for.

    save(file=tdm.file, tdm)
    save(file=dtm.file, dtm)
    ##save(file=file.path(data.path, "diss"), diss)
  } else {
    load(file=tdm.file)
    load(file=dtm.file)
    ##load(file=file.path(data.path, "diss")
  }

  return(list(tdm=tdm, dtm=dtm))
}


compute.commnet <- function(forest.corp, data.path) {
  commnet.file <- file.path(data.path, "commnet")
  doCompute <- !(file.exists(commnet.file))

  if (doCompute) {
    commnet <- adjacency(createedges(forest.corp$forest))
    save(file=commnet.file, commnet)
  } else {
    load(file=commnet.file)
  }
  
  return(commnet)
}


## These two calls are only relevant for the side effects -- they populate
## basedir/<ml>/subject resp. /content
## Iterate over all terms in termfreq, and create the adjacency matrix
## for the communication network associated with each term
extract.commnets <- function(forest, termfreq, repo.path, data.path) {
  cont.dir <- file.path(data.path, "commnet.terms", "content")
  subj.dir <- file.path(data.path, "commnet.terms", "subject")

  doCompute <- !(file.exists(cont.dir)) && !(file.exists(subj.dir))

  if (doCompute) {
    extract.commnet(forest, termfreq, "content", data.path)
    extract.commnet(forest, termfreq, "subject", data.path)
  }
}


compute.interest.networks <- function(termfreq, NUM.NET.SUBJECT, NUM.NET.CONTENT,
                                      data.path) {
  subject.file <- file.path(data.path, "net.subject")
  content.file <- file.path(data.path, "net.content")

  doCompute <- !(file.exists(subject.file)) && !(file.exists(content.file))

  if (doCompute) {
    net.subject <- gen.net("subject", termfreq, data.path, NUM.NET.SUBJECT)
    net.content <- gen.net("content", termfreq, data.path, NUM.NET.CONTENT)
    save(file=subject.file, net.subject)
    save(file=content.file, net.content)
  } else {
    load(file=subject.file)
    load(file=content.file)
  }

  return(list(subject=net.subject, content=net.content))
}


analyse.networks <- function(forest, interest.networks, communication.network) {
  ######### Analyse interest and communication (ICC) networks #######
  ## (very fast, no persistent storing necessary)
  networks.subj <- gen.cmp.networks(interest.networks$subject, communication.network)
  networks.cont <- gen.cmp.networks(interest.networks$content, communication.network)
  dat.subj <- gen.networks.df(networks.subj)
  dat.cont <- gen.networks.df(networks.cont)

  dat.icc <- data.frame(dat.subj, source="subject")
  dat.icc <- rbind(dat.icc, data.frame(dat.cont, source="content"))
  rm(dat.subj); rm(dat.cont)

  ####### Initiation-response (IR) structure for the mailing list ######
  ## TODO: Determine if any extremal values are outliers
  ## (this plot seems to be quite informative. Compare for multiple projects)
  dat.subj <- compute.initiate.respond(forest, networks.subj[[2]], networks.subj[[3]])
  dat.cont <- compute.initiate.respond(forest, networks.cont[[2]], networks.cont[[3]])
  dat.ir <- data.frame(dat.subj, source="subject")
  dat.ir <- rbind(dat.ir, data.frame(dat.cont, source="content"))
  rm(dat.subj); rm(dat.cont)

  return(list(icc=dat.icc, ir=dat.ir))
}


## ################### Analysis dispatcher ######################
## ################### Let the above rip ########################
timestamp <- function(text) {
  cat (text, ": ", date(), "\n")
}

dispatch.all <- function(conf, repo.path, resdir) {
  timestamp("start")
  corp.base <- gen.forest(conf, repo.path, resdir)
  timestamp("corp.base finished")

  ## #######
  ## Split the data into smaller chunks for time-resolved analysis
  dates <- do.call(c,
                   lapply(seq_along(corp.base$corp),
                          function(i) as.POSIXct(DateTimeStamp(corp.base$corp[[i]])))
                   )
  dates <- dates[!is.na(dates)]
  iter.weekly <- gen.iter.intervals(dates, 1)
  iter.4weekly <- gen.iter.intervals(dates, 4)

  ## Compute a list of intervals for the project release cycles
  tstamps <- get.release.dates(conf)

  release.intervals <- list(dim(tstamps)[1]-1)
  release.labels <- list(dim(tstamps)[1]-1)
  for (i in 1:(dim(tstamps)[1]-1)) {
    release.intervals[[i]] <- new_interval(tstamps$date[i],
                                           tstamps$date[i+1])
    release.labels[[i]] <- paste(tstamps$tag[i], tstamps$tag[i+1], sep="-")
  }

  ## The mailing list data may not cover the complete timeframe of
  ## the repository, so remove any empty intervals
  nonempty.release.intervals <- get.nonempty.intervals(dates, release.intervals)
  release.intervals <- release.intervals[nonempty.release.intervals]
  release.labels <- release.labels[nonempty.release.intervals]
  
  ## TODO: Find some measure (likely depending on the number of messages per
  ## time) to select suitable time intervals of interest. For many projects,
  ## weekly (and monthly) are much too short, and longer intervals need to
  ## be considered.
  periodic.analysis <- FALSE
  if (periodic.analysis) {
    analyse.sub.sequences(conf, corp.base, iter.weekly, repo.path, resdir,
                          paste("weekly", 1:length(iter.weekly), sep=""))
    analyse.sub.sequences(conf, corp.base, iter.4weekly, repo.path, resdir,
                          paste("4weekly", 1:length(iter.4weekly), sep=""))
  }

  analyse.sub.sequences(conf, corp.base, release.intervals, repo.path, resdir,
                        release.labels)

  ## #######
  ## Global analysis
  ## NOTE: We only compute the forest for the complete interval to allow for creating
  ## descriptive statistics.
  corp <- corp.base$corp
  forest.corp <- list(forest=make.forest(corp),
                      corp=corp,
                      corp.orig=corp.base$corp.orig)

  resdir.complete <- file.path(resdir, "complete")
  gen.dir(resdir.complete)
  save(file=file.path(resdir.complete, "forest.corp"), forest.corp)
}


analyse.sub.sequences <- function(conf, corp.base, iter, repo.path,
                                  data.path, labels) {
  if (length(iter) != length(labels))
    stop("Internal error: Iteration sequence and data prefix length must match!")

  timestamps <- do.call(c, lapply(seq_along(corp.base$corp),
                                  function(i) DateTimeStamp(corp.base$corp[[i]])))
  
  cat(length(corp.base$corp), "messages in corpus\n")
  cat("Date range is", as.character(int_start(iter[[1]])), "to",
      as.character(int_end(iter[[length(iter)]])), "\n")
  cat("=> Analysing ", conf$ml, "in", length(iter), "subsets\n")

  lapply.cluster <- function(x, FUN, ...) {
    snow::parLapply(getSetCluster(), x, FUN, ...)
  }

  if (tm::clusterAvailable() && length(iter) > 1) {
    do.lapply <- lapply.cluster

    ## NOTE: Exporting the global variable snatm.path is only required
    ## as long as includes.r sources the modified snatm package manually.
    clusterExport(getSetCluster(), "snatm.path")
    clusterCall(getSetCluster(), function() { source("includes.r"); return(NULL) })
  } else {
    do.lapply <- lapply
  }
  res <- do.lapply(1:length(iter), function(i) {
    ## Determine the corpus subset for the interval
    ## under consideration
    cat("Processing interval ", i, "\n");

    curr.int <- iter[[i]]
    idx <- which(timestamps >= int_start(curr.int) & timestamps < int_end(curr.int))
    corp.sub <- corp.base$corp[idx]
    
    forest.corp.sub <- list(forest=make.forest(corp.sub),
                            corp=corp.sub,
                            corp.orig=corp.base$corp.orig[idx])
    
    ## ... and perform all analysis steps
    data.path.local <- file.path(data.path, labels[[i]])
    gen.dir(data.path.local)
    save(file=file.path(data.path.local, "forest.corp"), forest.corp.sub)
    
    dispatch.steps(conf, repo.path, data.path.local, forest.corp.sub)
    cat(" -> Finished interval ", i, "\n")
  })
}

## User needs to make sure that data.path exists and is writeable
## dispatch.steps is called for every time interval that is considered
## in the analysis
dispatch.steps <- function(conf, repo.path, data.path, forest.corp) {
  ## TODO: Check how we can speed up prepare.text. And think about if the
  ## function is really neccessary. With stemming activated, I doubt
  ## that it really pays off.
###prep <- prepare.text(forest, progress=TRUE)
####save(file=file.path(data.path, paste("prep", ml, sep=".")), prep)
  communication.network <- compute.commnet(forest.corp, data.path)
  timestamp("communication.network finished")
  
  ## Returns tdm and dtm
  doc.matrices <- compute.doc.matrices(forest.corp, data.path)
  timestamp("doc.matrices finished")

  ## TODO: Provide per-ml keyword collections for the exclusion words
  termfreq <- findHighFreq(doc.matrices$tdm, exclude.list=unique(c(terms.d,
                                               terms.coll, terms.c,
                                               terms.programming)))
  write.table(data.frame(term=as.character(termfreq),
                         count=as.numeric(attr(termfreq, "names"))),
              file=file.path(data.path, "termfreq.txt"), sep="\t",
              row.names=FALSE, quote=FALSE)
  timestamp("termfreq finished")

  ## NOTE: For most projects, technical left-overs (like footers from majordomo
  ## etc.) will appear in the termfreq list. To find out which elements need
  ## to be removed from emails by grepping for the artefacts, use
  ## id <- function(x) return(x)
  ## text <- sapply(forest.corp$corp[1:5000], id)
  ## grep("keyword", text)
  ## ... and then inspect the appropriate messages in corp.orig to see which additional
  ## filter needs to be applied
  
  extract.commnets(forest.corp, termfreq, repo.path, data.path)
  timestamp("extract.commnets finished")
  
  ## TODO: Find justifiable heuristics for these configurable parameters
  NUM.NET.SUBJECT <- 25
  NUM.NET.CONTENT <- 50
  interest.networks <- compute.interest.networks(termfreq, NUM.NET.SUBJECT,
                                                 NUM.NET.CONTENT,
                                                 data.path)
  
  networks.dat <- analyse.networks(forest.corp$forest, interest.networks,
                                   communication.network)
  timestamp("networks finished")

  ## Compute base data for time series analysis
  msgs <- lapply(forest.corp$corp, function(x) { as.POSIXct(DateTimeStamp(x)) })
  msgs <- do.call(c, msgs)
  msgs.ts <- zoo(rep(1,length(msgs)), order.by=msgs)

  ## ... and create smoothed variants
  HOURS.SMOOTH <- c(24,28,72)
  ts.df <- do.call(rbind, lapply(HOURS.SMOOTH,
                              function(x) gen.agg.smooth.ts(msgs.ts, x)))
  ts.df$smooth <- as.factor(ts.df$smooth)

  ## The exported table has three columns: date (obvious), value (smoothed
  ## activity factor; roughly number of messages per day), and smooth (hours
  ## used for smoothing window)
  df.export <- ts.df
  df.export$date <- as.numeric(df.export$date)
  write.table(df.export,
              file.path(data.path, "ts.txt"), row.names=F, sep = "\t", quote=F)

  ## Compute descriptive statistics
  ## NOTE: forest needs to available in the defining scope for the
  ## following four helper functions
  forest <- forest.corp$forest
  authors.per.thread <- function(i) {
    length(unique(forest[forest[,"threadID"]==i, "author"]))
  }
  messages.per.thread <- function(i) {
    length(forest[forest[,"threadID"]==i, "subject"])
  }
  get.subject <- function(i) {
    as.character(forest[forest[,"threadID"]==i, "subject"][1])
  }
  get.authors <- function(threadID) {
    unique(forest[forest[,"threadID"]==threadID, "author"])
  }

  ## Determine authors and messages _per thread_
  num.authors <- sapply(unique(forest[,"threadID"]), authors.per.thread)
  num.messages <- sapply(unique(forest[,"threadID"]), messages.per.thread)
  thread.info <- data.frame(authors=num.authors, messages=num.messages,
                            tid=attr(num.messages, "names"))

  d.auth <- density(thread.info$authors)
  d.msg <- density(thread.info$messages)
  thread.densities <- rbind(data.frame(num=d.auth$x, density=d.auth$y,
                                       type="Authors"),
                            data.frame(num=d.msg$x, density=d.msg$y,
                                       type="Messages"))

  ## Infer the larges threads as measured by the number of messages per thread
  largest.threads.msgs <- sort(thread.info$messages, decreasing=T, index.return=T)
  ## ... and determine the subjects that started the threads
  ## TODO: Maybe the arbitrary constant 20 should be chosen by some
  ## adaptive mechanism
  subjects.msgs <- sapply(largest.threads.msgs$ix, get.subject)
  if (length(subjects.msgs) > 20) {
    subjects.msgs <- subjects.msgs[1:20]
    subjects.counts <- largest.threads.msgs$x[1:20]
  }

  ## freq_subjects stores the subjects that received the highest
  ## attention, at most 20 of them.
  write.table(data.frame(count=subjects.counts, subject=subjects.msgs),
              file=file.path(data.path, "freq_subjects.txt"), sep="\t",
              row.names=FALSE, quote=FALSE, col.names=TRUE)

  ## thread_info.txt stores the number of authors and messages
  ## per thread (each thread is identified with a unique tid)
  write.table(thread.info,
              file=file.path(data.path, "thread_info.txt"), sep="\t",
              row.names=FALSE, quote=FALSE)

  ## thread_densities.txt stores a density estimation of how many threads
  ## there are with a given number of authors resp. threads. Plot
  ## density~num|type
  write.table(thread.densities,
              file=file.path(data.path, "thread_densities.txt"), sep="\t",
              row.names=FALSE, quote=FALSE)

  ## TODO: Can we classify the messages into content catgories, e.g., technical
  ## discussions, assistance (helping users), and code submissions?

  ## TODO: This should be represented by a class
  res <- list(doc.matrices=doc.matrices, termfreq=termfreq,
              interest.networks=interest.networks,
              networks.dat=networks.dat,
              ts.df=ts.df,
              thread.info=thread.info,
              thread.densities=thread.densities)
  save(file=file.path(data.path, "vis.data"), res)
  
  ## ######### End of actual computation. Generate graphs etc. ##############
  dispatch.plots(conf, data.path, res)
}


create.network.plots <- function(conf, plots.path, res) {
  ## NOTE: The correlation threshold is quite critical.
  ## TODO: Find some automatical means based on the maximal number of edges.
  pdf(file.path(plots.path, "tdm_plot.pdf"))
  plot(res$doc.matrices$tdm, terms=res$termfreq, corThreshold=0.15, weighting=TRUE)
  dev.off()

  ## NOTE: larger threshold -> less authors
  ## edgelist is interest.networks$subject[[1]]
  ## adjacency matrix (net in Bohn's notation) is interest.networks$subject[[2]]
  ## respectively same elements in net.content
  gen.termplot(res$interest.networks$subject[[1]],
               res$interest.networks$subject[[2]],
               NA, file.path(plots.path, "termplot_subject.pdf"), max.persons=30)
  gen.termplot(res$interest.networks$content[[1]],
               res$interest.networks$content[[2]],
               NA, file.path(plots.path, "termplot_content.pdf"), max.persons=40)
  
  ## Visualise the correlation between communication network and interests
  ## (not sure if this is really the most useful piece of information)
  g <- ggplot(res$networks.dat$icc, aes(x=centrality, y=dist, colour=type)) +
    geom_line() +
      geom_point() + facet_grid(source~.)
  ggsave(file.path(plots.path, "interest.communication.correlation.pdf"), g)

  ## TODO: It can happen that deg is NaN here. (in the worst case, all entries
  ## are NaNs, leading to a ggplot2 fault). Check under which circumstances this
  ## can happen.
  g <- ggplot(res$networks.dat$ir, aes(x=x, y=y)) +
    geom_point(aes(size=deg, colour=col)) +
      scale_x_log10() + scale_y_log10() + ggtitle(conf$project) +
        facet_grid(source~.) +
          xlab("Messages initiated (log. scale)") + ylab("Responses (log. scale)")
  ggsave(file.path(plots.path, "init.response.log.pdf"), g)

  ## TODO: Maybe we should jitter the points a little
  g <- ggplot(res$networks.dat$ir, aes(x=x, y=y)) +
    geom_point(aes(size=deg, colour=col)) +
      ggtitle(conf$project) + xlab("Messages initiated") + ylab("Responses")
  ggsave(file.path(plots.path, "init.response.pdf"), g)
}

create.ts.plots <- function(conf, plots.path, res) {
  g <- ggplot(res$ts.df, aes(x=date, y=value, colour=smooth)) +
    geom_line() + xlab("Date") + ylab("Mailing list activity") +
    ggtitle(paste("Mailing list analysis for", conf$project))
  ggsave(file.path(plots.path, "ts.pdf"), g)
}

create.descriptive.plots <- function(conf, plots.path, res) {
  ## How focused are discussions, respectively how does the number
  ## of authors scale with the number of messages per thread?
  g <- ggplot(res$thread.info, aes(x=authors, y=messages)) + geom_point() +
    xlab("Authors per thread") + ylab("Messages per thread") + geom_smooth() +
    ggtitle(conf$project)
  ggsave(file.path(plots.path, "auth_msg_scatter.pdf"), g)

  ## Distribution of authors and messages per thread
  thread.info.molten <- melt(res$thread.info)
  g <- ggplot(thread.info.molten, aes(x=variable, y=value)) + geom_boxplot() +
    scale_y_log10() + xlab("Type") + ylab("Number per thread") +
    ggtitle(conf$project)
  ggsave(file.path(plots.path, "auth_msg_dist.pdf"), g)

  g <- ggplot(res$thread.densities, aes(x=num, y=density)) + geom_line() +
       scale_y_sqrt() + facet_grid(type~.) + xlab("Number per thread") +
       ylab("Density") + ggtitle(conf$project)
  ggsave(file.path(plots.path, "thread_densities.pdf"), g)

  thread.combined <- rbind(data.frame(num=res$thread.info$authors,
                                      type="Authors"),
                           data.frame(num=res$thread.info$messages,
                                      type="Messages"))
  g <- ggplot(thread.combined, aes(x=num, colour=type, fill=type)) +
    geom_histogram(binwidth=1, position="dodge") + scale_y_sqrt() +
    xlab("Amount of thread contributions") +
    ylab("Number of threads (sqrt transformed)") +
    scale_size("Type of contribution") + ggtitle(conf$project)
  ggsave(file.path(plots.path, "thread_contributions.pdf"), g)
}

dispatch.plots <- function(conf, data.path, res) {
  plots.path <- file.path(data.path, "plots")
  gen.dir(plots.path)

  create.network.plots(conf, plots.path, res)
  create.ts.plots(conf, plots.path, res)
  create.descriptive.plots(conf, plots.path, res)
}
