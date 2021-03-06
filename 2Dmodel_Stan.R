# Two-Dimensional IRT ideal point model, with vote parameters (Beta) used as identifying constraints 
# as per Simon Jackman ("Multidimensional analysis of roll call data via Bayesian simulation: 
# identification, estimation, inference, and model checking", Political Analysis, Vol 9, Issue 3, 2001).
library(rstan)
library(coda)
library(plyr)
library(dplyr)
library(readr)


# The following assumes that you have a dataset called "data", of votes and legislator details
# 'FullID' refers to the legislator name and party; 'VoteNumber' to the number associated with the
# vote. 'Vote' is the actual vote of each legislator. It should be numeric and in the form 'Yes'=1;
# 'No' = 0; absent, NA = NA.

# If you don't have this type of data already, we can use this example:

VoteData  <-  read_csv("https://github.com/RobertMyles/R-Scripts-Bayesian-Ideal-Point-IRT/blob/master/Senate_Example.csv?raw=true")

# build the vote matrix
VoteData$FullID <- paste(VoteData$SenatorUpper, VoteData$Party, sep=":")
NameID <- unique(VoteData$FullID)
J <- length(unique(NameID))
K <- length(unique(VoteData$VoteNumber))

VoteData$Vote[VoteData$Vote=="S"] <- 1
VoteData$Vote[VoteData$Vote=="N"] <- 0
VoteData$Vote[VoteData$Vote %in% c("O", "A", NA)] <- NA

y <- matrix(NA, J, K)
Rows <- match(VoteData$FullID, NameID)
Cols <- unique(VoteData$VoteNumber)
Columns <- match(VoteData$VoteNumber, Cols)

for(i in 1:dim(VoteData)[1]){
  y[Rows[i],Columns[i]] <- VoteData$Vote[i]
}

y <- matrix(as.numeric(unlist(y)),nrow=nrow(y))
dimnames(y) <- list(unique(NameID), unique(VoteData$VoteNumber))

# The vote matrix is organised so that the constraints appear in the first two rows and 
# columns (just for convenience).
# Constraints are set up so that y[1,] is a right-wing, conservative legislator
# and y[2,] is a left-wing legislator. For the vote parameters, y[,1] is given a negative constraint and 
# y[,2] a positive constraint, based on the content of the vote proposals. These should be
# set according to the case and based on qualitative & theoretical knowledge.
# In the model below, I use 'hard' constraints (a fixed point with a tight prior); this is
# because the use of truncations (such as: theta[1,1] ~  normal(1, 1) t[0,]; ) can lead to 
# lots of divergent transitions in Stan if you don't have informative data. But you can just switch the
# constraints to the line above if you prefer softer constraints.
# 
# You also don't have to fix the vote parameters like I do here, you can fix (or constrain) the position 
# of three legislators in the 2D space if you have good theoretical knowledge as to where they 
# should be located. In one dimension, this is usually straightforward, it becomes more difficult
# in more dimensions.

# Legislator data (for graphing and further analysis):

ldata <- data_frame(FullID = unique(NameID), 
          Party = VoteData$Party[match(unique(NameID), VoteData$FullID)], 
          GovCoalition=VoteData$GovCoalition[match(unique(NameID), VoteData$FullID)],
          Name=VoteData$SenatorUpper[match(unique(NameID), VoteData$FullID)], 
          State=VoteData$State[match(unique(NameID), VoteData$FullID)])

########################################################################################################
#  Model in Stan:

stan.code <- "
data {
  int<lower=1> J;                 //Legislators
  int<lower=1> K;                 //Proposals
  int<lower=1> N;                 //no. of observations
  int<lower=1, upper=J> j[N];     //Legislator for observation n
  int<lower=1, upper=K> k[N];     //Proposal for observation n
  int<lower=0, upper=1> y[N];     //Vote of observation n
  int<lower=1> D;                 //No. of dimensions
}
parameters {
  real alpha[K];                    //difficulty (intercept)
  matrix[K,D] beta;                 //discrimination (slope)
  matrix[J,D] theta;                //latent trait (ideal points)
}
model {
  alpha ~ normal(0,10); 
  to_vector(beta) ~ normal(0,10); 
  to_vector(theta) ~ normal(0,1); 
  theta[1,1] ~  normal(1, .01);     //constraints, ideal points, dimension 1
  theta[2,1] ~ normal(-1, .01);  
  beta[1,2] ~ normal(-4, 2);        // beta constraints
  beta[2,2] ~ normal(4, 2); 
  beta[1,1] ~ normal(0, .1); 
  beta[2,1] ~ normal(0, .1); 
for (n in 1:N)
 y[n] ~ bernoulli_logit(theta[j[n],1] * beta[k[n],1] + theta[j[n],2] * beta[k[n],2] - alpha[k[n]]);
}"


N <- length(y)
j <- rep(1:J, times=K)
k <- rep(1:K, each=J)
D <- 2

#delete missing values
missing <- which(is.na(y))
N <- N - length(missing)
j <- j[-missing]
k <- k[-missing]
y <- y[-missing]


stan.data <- list(J=J, K=K, N=N, j=j, k=k, y=y, D=D)

# Stan run:
# No inits here, but straightforward to include

stan.fit <- stan(model_code=stan.code, data=stan.data, iter=100, warmup=25, chains=4, verbose=TRUE, cores=4, seed=1234)

# Some diagnostics
stan_rhat(stan.fit, bins=60)


# Nice plot:
MC <- As.mcmc.list(stan.fit)
sMS <- summary(MC)
fft <- first(grep("theta", row.names(sMS$statistics)))
llt <- last(grep("theta", row.names(sMS$statistics)))
Theta <- sMS$statistics[fft:llt,1]
ThetaQ <- sMS$quantiles[fft:llt,c(1,5)]
Theta <- as.data.frame(cbind(Theta, ThetaQ))
Theta1 <- Theta[seq(1, length(row.names(Theta)), by=2),] #first dimension
Theta2 <- Theta[seq(2, length(row.names(Theta)), by=2),] # second
colnames(Theta1) <- c("MeanD1", "LowerD1", "UpperD1")
colnames(Theta2) <- c("MeanD2", "LowerD2", "UpperD2")
Theta1$FullID <- ldata$FullID
Theta2$FullID <- ldata$FullID
row.names(Theta1) <- NULL
row.names(Theta2) <- NULL
Theta <- merge(Theta1, Theta2, by="FullID")
rm(ThetaQ, Theta1, Theta2)
Theta <- merge(Theta, ldata, by="FullID")

# Create polygons for graphing (here it is by membership of the government coalition):
find_hull <- function(Theta) Theta[chull(Theta$MeanD1, Theta$MeanD2), ]
hulls <- ddply(Theta, "GovCoalition", find_hull)

ggplot(Theta, aes(x=MeanD1, y=MeanD2, colour=GovCoalition, fill=GovCoalition)) + geom_point(shape=19, size=3) + geom_polygon(data=hulls, alpha=.18) + geom_text(aes(y=MeanD2, label=FullID, colour=GovCoalition), size=2.5, vjust=-0.75) + scale_colour_manual(values=c("red", "blue")) + scale_fill_manual(values=c("red", "blue")) + theme_bw() + theme(axis.text.y=element_blank(), axis.ticks.y=element_blank(), axis.title=element_blank(), legend.position="none") 
        #+ scale_x_continuous(limits=c(-1.9, 2.25)) #if necessary to adjust scale
