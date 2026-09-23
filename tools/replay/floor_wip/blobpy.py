import numpy as np
def integral(a):
    I=np.zeros((a.shape[0]+1,a.shape[1]+1),np.int64); I[1:,1:]=a.astype(np.int64).cumsum(0).cumsum(1); return I
def boxsum(I,r):
    H,W=I.shape[0]-1,I.shape[1]-1
    ys=np.arange(H); xs=np.arange(W)
    y0=np.clip(ys-r,0,H); y1=np.clip(ys+r+1,0,H); x0=np.clip(xs-r,0,W); x1=np.clip(xs+r+1,0,W)
    S=I[y1][:,x1]-I[y0][:,x1]-I[y1][:,x0]+I[y0][:,x0]
    N=np.outer(y1-y0,x1-x0)
    return S,N
def blobs(a,r=6.0,minscore=12,top=5):
    I=integral(a)
    rIn=max(2,round(0.45*r)); r0=round(1.2*r)+1; r1=r0+max(3,round(0.6*r)); o0=r1+2; o1=o0+max(4,round(0.8*r))
    Si,Ni=boxsum(I,rIn); S0,N0=boxsum(I,r0); S1,N1=boxsum(I,r1); So0,No0=boxsum(I,o0); So1,No1=boxsum(I,o1)
    inn=Si/Ni; ring=(S1-S0)/np.maximum(1,N1-N0); outer=(So1-So0)/np.maximum(1,No1-No0)
    score=inn-ring; ok=(score>=minscore)&(ring-outer<=0.35*score+4)
    sc=np.where(ok,score,0)
    out=[]
    for _ in range(top):
        k=np.argmax(sc); y,x=divmod(k,sc.shape[1])
        if sc[y,x]<=0: break
        out.append((x,y,float(sc[y,x]),float(inn[y,x]),float(ring[y,x])))
        sc[max(0,y-15):y+16,max(0,x-15):x+16]=0
    return out
