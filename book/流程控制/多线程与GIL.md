
# 多线程与GIL

## GIL

CPython解释器本身就不是线程安全的,因此有全局解释器锁(GIL),一次只允许使用一个线程执行 Python 字节码。因此,一个 Python 进程通常不能同时使用多个 CPU 核心。

编写 Python 代码时无法控制 GIL;不过,执行耗时的任务时,可以使用一个内置的函数 或一个使用 C 语言编写的扩展释放 GIL。其实,有个使用 C 语言编写的 Python 库能管理 GIL,自行启动操作系统线程,利用全部可用的 CPU 核心。这样做会极大地增加库代码的 复杂度,因此大多数库的作者都不这么做。

然而,标准库中所有执行阻塞型 I/O 操作的函数,在等待操作系统返回结果时都会释放 GIL。这意味着在 Python 语言这个层次上可以使用多线程处理io阻塞问题,而 I/O 密集型 Python 程序能从中受益:一个 Python 线程等待网络响应时,阻塞型 I/O 函数会释放 GIL,再运行一个线程。

### 为什么需要GIL

GIL是必须的，这是Python设计的问题：Python解释器是非线程安全的。这意味着当从线程内尝试安全的访问Python对象的时候将有一个全局的强制锁。在任何时候，仅仅一个单一的线程能够获取Python对象或者C API。每100个字节的Python指令解释器将重新获取锁，这（潜在的）阻塞了I/O操作。因此CPU密集型的代码使用线程库时，不会获得性能的提高.


## 使用concurrent.futures进行高层抽象的多线程操作

concurrent.futures提供两种编程模型:

+ 并行任务模型
    单独任务独立使用自己的过程和数据,多任务独立并行计算

+ MapReduce模型
    为各个线程分发数据执行相同的过程
    

### 并行任务模型

这个模型使用submit提交任务到上下文管理器,之后使用返回对象的result()方法阻塞io等待任务完成


```python
from concurrent.futures import ThreadPoolExecutor,as_completed
from random import randrange
from time import time
```


```python
def arcfour(key, in_bytes, loops=20):
    """rc4算法"""
    kbox = bytearray(256)  # create key box
    for i, car in enumerate(key):  # copy key and vector
        kbox[i] = car
    j = len(key)
    for i in range(j, 256):  # repeat until full
        kbox[i] = kbox[i-j]

    # [1] initialize sbox
    sbox = bytearray(range(256))

    # repeat sbox mixing loop, as recommened in CipherSaber-2
    # http://ciphersaber.gurus.com/faq.html#cs2
    j = 0
    for k in range(loops):
        for i in range(256):
            j = (j + sbox[i] + kbox[i]) % 256
            sbox[i], sbox[j] = sbox[j], sbox[i]

    # main loop
    i = 0
    j = 0
    out_bytes = bytearray()

    for car in in_bytes:
        i = (i + 1) % 256
        # [2] shuffle sbox
        j = (j + sbox[i]) % 256
        sbox[i], sbox[j] = sbox[j], sbox[i]
        # [3] compute t
        t = (sbox[i] + sbox[j]) % 256
        k = sbox[t]
        car = car ^ k
        out_bytes.append(car)

    return out_bytes
```


```python
clear = bytearray(b'1234567890' * 100000)
t0 = time()
cipher = arcfour(b'key', clear)
print('elapsed time: %.2fs' % (time() - t0))
result = arcfour(b'key', cipher)
assert result == clear, '%r != %r' % (result, clear)
print('elapsed time: %.2fs' % (time() - t0))
print('OK')
```

    elapsed time: 0.86s
    elapsed time: 1.73s
    OK



```python
def crypto_process(size, key):
    in_text = bytearray(randrange(256) for i in range(size))
    cypher_text = arcfour(key, in_text)
    out_text = arcfour(key, cypher_text)
    assert in_text == out_text, 'Failed arcfour_test'
    return size
    
def main(workers=None):
    JOBS = 12
    SIZE = 2**18

    KEY = b"'Twas brillig, and the slithy toves\nDid gyre"
    STATUS = '{} workers, elapsed time: {:.2f}s'
    if workers:
        workers = int(workers)
    t0 = time()

    with ThreadPoolExecutor(workers) as executor:
        actual_workers = executor._max_workers
        to_do = []
        for i in range(JOBS, 0, -1):
            size = SIZE + int(SIZE / JOBS * (i - JOBS/2))
            job = executor.submit(crypto_process, size, KEY)
            to_do.append(job)

        for future in as_completed(to_do):
            res = future.result()
            print('{:.1f} KB'.format(res/2**10))

    print(STATUS.format(actual_workers, time() - t0))
```


```python
main(1)
```

    384.0 KB
    362.7 KB
    341.3 KB
    320.0 KB
    298.7 KB
    277.3 KB
    256.0 KB
    234.7 KB
    213.3 KB
    192.0 KB
    170.7 KB
    149.3 KB
    1 workers, elapsed time: 10.66s



```python
main(2)
```

    362.7 KB
    384.0 KB
    320.0 KB
    341.3 KB
    277.3 KB
    298.7 KB
    234.7 KB
    256.0 KB
    213.3 KB
    192.0 KB
    149.3 KB
    170.7 KB
    2 workers, elapsed time: 13.25s



```python
main(4)
```

    320.0 KB
    362.7 KB
    341.3 KB
    384.0 KB
    256.0 KB
    298.7 KB
    277.3 KB
    234.7 KB
    149.3 KB
    170.7 KB
    213.3 KB
    192.0 KB
    4 workers, elapsed time: 12.75s


### MapReduce模型

这种模式可能更加被大家熟悉,同一个流程,将容器中的数据一条一脚放入子进程运算,最终也结果也会被放入容器中.最后可以将收集来的数据在主进程中进行处理


```python
import math
PRIMES = [
    112272535095293,
    112582705942171,
    112272535095293,
    115280095190773,
    115797848077099,
    1099726899285419]
def is_prime(n):
    if n % 2 == 0:
        return False

    sqrt_n = int(math.floor(math.sqrt(n)))
    for i in range(3, sqrt_n + 1, 2):
        if n % i == 0:
            return False
    return True
```


```python
[is_prime(i) for i in PRIMES]
```




    [True, True, True, True, True, False]




```python
def ProcessPool_prime(PRIMES= PRIMES ,workers=4):
    with ThreadPoolExecutor(max_workers=workers) as executor:
        total = []
        for prime in executor.map(is_prime, PRIMES):
            #print('%d is prime: %s' % (number, prime))
            total.append(prime)
    return total
```


```python
ProcessPool_prime()
```




    [True, True, True, True, True, False]



## `*`使用装饰器无痛多线程

[Tomorrow](https://github.com/madisonmay/Tomorrow)模块模块是一个ThreadPoolExecutor模块的封装,虽然只是简单地接口变化,但带来的写法上的进化非常巨大,值得一试,我们可以使用pip安装这个模块

要使用多线程只需要使用装饰器threads并设置最大线程和断开时间timeout(默认为None)即可


```python
from tomorrow import threads

@threads(4)
def is_prime_2(n):
    print(str(n)+":start")
    if n % 2 == 0:
        print(str(n)+":end")
        return False

    sqrt_n = int(math.floor(math.sqrt(n)))
    for i in range(3, sqrt_n + 1, 2):
        if n % i == 0:
            print(str(n)+":end")
            return False
    print(str(n)+":end")
    return True
```


```python
responses = [is_prime_2(i) for i in PRIMES]
```

    112272535095293:start112582705942171:start112272535095293:start115280095190773:start
    
    
    



```python
responses
```




    [<tomorrow.tomorrow.Tomorrow at 0x10cf0e898>,
     <tomorrow.tomorrow.Tomorrow at 0x10cf0edd8>,
     <tomorrow.tomorrow.Tomorrow at 0x10cf0ed30>,
     <tomorrow.tomorrow.Tomorrow at 0x10ca71198>,
     <tomorrow.tomorrow.Tomorrow at 0x10ca71320>,
     <tomorrow.tomorrow.Tomorrow at 0x10ca71400>]



    112272535095293:end112582705942171:end
    
    115797848077099:start1099726899285419:start
    


## 使用线程池进行相对底层的多进程操作

线程池的方式很适合批量创建子线程.线程池模块藏在多进程模块`multiprocessing.pool`下,`ThreadPool`

对ThreadPool对象调用join()方法会等待所有子进程执行完毕，调用join()之前必须先调用close()，调用close()之后就不能继续添加新的Process了。


请注意输出的结果，task 0，1，2，3是立刻执行的，而task 4要等待前面某个task完成后才执行，这是因为Pool的默认大小在我的电脑上是4，因此，最多同时执行4个进程。这是Pool有意设计的限制，并不是操作系统的限制。如果改成p = Pool(5)就可以同时跑5个进程。


由于Pool的默认大小是CPU的核数，如果你不幸拥有8核CPU，你要提交至少9个子进程才能看到上面的等待效果。


除了使用apply_async方法外,还有apply，map和map_async可以用于线程池的计算,编程模型也是如concurrent.futures一样分为两类

+ 并行任务模型

    + apply 单一任务布置
    + apply_async 非阻塞单一任务布置
    
+ MapReduce模型

    + map 同系统的map方法
    + map_async 非阻塞的map

#### apply_async


```python
from multiprocessing.pool import ThreadPool as Pool
import os, time, random

def long_time_task(name):
    print('运行任务 %s (%s)...' % (name, os.getpid()))
    start = time.time()
    time.sleep(random.random() * 3)
    end = time.time()
    print('任务 %s 执行了 %0.2f 秒.' % (name, (end - start)))

```

    112272535095293:end115280095190773:end
    
    1099726899285419:end



```python
print('父线程 %s.' % os.getpid())
p = Pool(4)
for i in range(5):
    p.apply_async(long_time_task, args=(i,))#创建非阻塞子线程用这个
print('等待所有子线程完成...')
p.close()
p.join()
print('所有子线程完成了.')
```

    父线程 1328.
    115797848077099:end
    等待所有子线程完成...运行任务 1 (1328)...运行任务 0 (1328)...
    运行任务 2 (1328)...
    
    
    运行任务 3 (1328)...
    任务 2 执行了 1.40 秒.
    运行任务 4 (1328)...
    任务 1 执行了 1.57 秒.
    任务 3 执行了 1.97 秒.
    任务 4 执行了 1.05 秒.
    任务 0 执行了 2.83 秒.
    所有子线程完成了.


#### map_async


```python
from multiprocessing.pool import ThreadPool as Pool
from time import sleep

def f(x):
    return x*x

# start 4 worker processes
pool = Pool(processes=4)
print("map: ",pool.map(f, range(10)))
print("imap:")
for i in pool.imap_unordered(f, range(10)):
    print(i)

# evaluate "f(10)" asynchronously
res = pool.apply_async(f, [10])
print("apply:",res.get(timeout=1))             # prints "100"

# make worker sleep for 10 secs
res = pool.apply_async(sleep, [10])
print(res.get(timeout=1))             # raises multiprocessing.TimeoutError

```

    map:  [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]
    imap:
    0
    1
    4
    9
    16
    25
    36
    49
    64
    81
    apply: 100



    ---------------------------------------------------------------------------

    TimeoutError                              Traceback (most recent call last)

    <ipython-input-17-21bbb913a07a> in <module>()
         18 # make worker sleep for 10 secs
         19 res = pool.apply_async(sleep, [10])
    ---> 20 print(res.get(timeout=1))             # raises multiprocessing.TimeoutError
    

    ~/LIB/CONDA/anaconda/lib/python3.6/multiprocessing/pool.py in get(self, timeout)
        602         self.wait(timeout)
        603         if not self.ready():
    --> 604             raise TimeoutError
        605         if self._success:
        606             return self._value


    TimeoutError: 


获取进程池中的运算结果


```python
from multiprocessing.pool import ThreadPool as Pool
import time

def func(msg):
    print("msg:", msg)
    time.sleep(1)
    print("end")
    return "done " + msg


pool = Pool(processes=4)
result = []
for i in range(3):
    msg = "hello %d" %(i)
    result.append(pool.apply_async(func, (msg, )))
pool.close()
pool.join()
for res in result:
    print(":::", res.get())
print("Sub-process(es) done.")
```

    msg:msg:msg:   hello 1hello 2hello 0
    
    
    end
    endend
    
    ::: done hello 0
    ::: done hello 1
    ::: done hello 2
    Sub-process(es) done.


## 更底层的多线程编程
`threading`模块提供了一个高层的API来提供线程的并发性。这些线程并发运行并共享内存。 多线程看着多么美好的,但因为数据安全的问题被加了锁..所以永远是单核运行,不细说了看个简单的用法吧

下面来看threading模块的具体用法：


```python
import threading
import time

def worker(i):
    print(i)
    time.sleep(1)
    print("AWAKE")

for i in range(5):
    t = threading.Thread(target=worker,args=(i,))
    t.start()
print("closed")
```

    102
    
    
    3
    4
    closed
    AWAKEAWAKEAWAKE
    
    
    AWAKE
    AWAKE


对比下不用多线程:


```python
def worker(i):
    print(i)
    import time
    time.sleep(1)
    print("AWAKE")

for i in range(5):
    worker(i)

```

    0
    AWAKE
    1
    AWAKE
    2
    AWAKE
    3
    AWAKE
    4
    AWAKE


### 一个相对复杂的例子


```python
from threading import Thread
import os
#子线程要执行的代码
def run_proc(name):
    for i in range(3):
        print(u'子线程 %s (%s)...' % (name, os.getpid()))
    print(u'子线程结束.')

print(u'父线程 {}.'.format(os.getpid()))
p = Thread(target=run_proc, args=('test',))
print(u'子线程要开始啦.')
p.start()
for i in range(3):
    print(u'父线程{pid}进行中...'.format(pid = os.getpid()))
p.join()
print(u"父线程结束啦")
```

    父线程 1328.
    子线程要开始啦.
    父线程1328进行中...子线程 test (1328)...
    
    父线程1328进行中...子线程 test (1328)...
    
    父线程1328进行中...子线程 test (1328)...
    
    父线程结束啦子线程结束.
    


### 使用Thread作为父类自定义子线程

Thread的子类需要重写run方法


```python
from threading import Thread

from queue import Queue

class Processor(Thread):

    def __init__(self, queue, idx):
        super(Processor, self).__init__()
        self.queue = queue
        self.idx = idx

    def return_name(self):
        ## NOTE: self.name is an attribute of multiprocessing.Process
        return "Thread idx=%s is called '%s'" % (self.idx, self.name)

    def run(self):
        self.queue.put(self.return_name())
        
processes = list()
q = Queue()
for i in range(0,5):
    p=Processor(queue=q, idx=i)
    processes.append(p)
    p.start()
for proc in processes:
    proc.join()
    ## NOTE: You cannot depend on the results to queue / dequeue in the
    ## same order
    print("RESULT: {}".format(q.get()))
```

    RESULT: Thread idx=0 is called 'Thread-31'
    RESULT: Thread idx=1 is called 'Thread-32'
    RESULT: Thread idx=2 is called 'Thread-33'
    RESULT: Thread idx=3 is called 'Thread-34'
    RESULT: Thread idx=4 is called 'Thread-35'


创建子线程时，只需要传入一个执行函数和函数的参数，创建一个Thread实例，用start()方法启动，这样创建进程比fork()简单。

join()方法可以等待子线程结束后再继续往下运行，通常用于线程间的同步。

可以看到我们的父线程进行完了子线程才进行.其实当执行start方法的时候我们就已经把线程创建好并给他任务了. 虽然线程启动了,但我们并不能知道它啥时候运算完成.这时候用join方法来确认是否执行完了(通过阻塞主线程),也就是起个等待结果的作用.

## 使用队列管理线程

线程安全是多线程编程中最不容易的事儿,线程间同步,互斥数据共享一直是要考虑的问题,而最常见的就是用队列实现管理线程了.

### 生产者消费者模型
队列最常见的用处就是在生产者消费者模式中作为数据缓冲区.以下就是一个生产者消费者模式的例子


```python
import queue as Queue
import threading
import random
```


```python
class Producer(threading.Thread):
    """生产者"""
    def __init__(self,q,con,name):
        super(Producer,self).__init__()
        self.q = q
        self.name = name
        self.con = con
        print("生产者{self.name}产生了".format(self=self))

    def run(self):
        count = 3 #只生产满3轮,要不然就会无限循环出不去了
        while count>0:
            #global writelock
            self.con.acquire()
            if self.q.full():
                print("队列满了,生产者等待")
                count-=1
                self.con.wait()

            else:
                value = random.randint(0,10)
                print("{self.name}把值{self.name}:{value}放入了队列".format(self=self,value=value))
                self.q.put("{self.name}:{value}".format(self=self,value=value))
            self.con.notify()
        self.con.release()
```


```python
class Consumer(threading.Thread):
    """消费者"""
    def __init__(self,q,con,name):
        super(Consumer,self).__init__()
        self.q = q
        self.name = name
        self.con = con
        print("消费者{self.name}产生了".format(self=self))

    def run(self):
        while True:
            #global writelock
            self.con.acquire()
            if self.q.empty():

                print("队列空了,消费者等待")
                self.con.wait()
            else:
                value = self.q.get()

                print("{self.name}从队列中获取了{self.name}:{value}".format(self=self,
                                                                         value=value))
                self.con.notify()
            self.con.release()
```


```python
q = Queue.Queue(10)
con = threading.Condition()
p1 = Producer(q,con,"P1")
p1.start()
p2 = Producer(q,con,"P2")
p2.start()
c1 = Consumer(q,con,"C1")
c1.start()
```

    生产者P1产生了P1把值P1:5放入了队列
    
    P1把值P1:8放入了队列生产者P2产生了
    
    P1把值P1:8放入了队列消费者C1产生了
    
    P1把值P1:7放入了队列
    队列满了,生产者等待C1从队列中获取了C1:P1:5P1把值P1:3放入了队列
    C1从队列中获取了C1:P1:8
    
    
    P1把值P1:3放入了队列C1从队列中获取了C1:P1:8
    
    P1把值P1:6放入了队列C1从队列中获取了C1:P1:7
    
    P1把值P1:2放入了队列C1从队列中获取了C1:P1:3
    
    P1把值P1:10放入了队列C1从队列中获取了C1:P1:3
    
    P1把值P1:0放入了队列C1从队列中获取了C1:P1:6
    
    队列满了,生产者等待队列满了,生产者等待C1从队列中获取了C1:P1:2
    
    
    P1把值P1:8放入了队列C1从队列中获取了C1:P1:10
    
    P1把值P1:7放入了队列C1从队列中获取了C1:P1:0
    
    P1把值P1:0放入了队列队列空了,消费者等待
    
    P1把值P1:3放入了队列C1从队列中获取了C1:P1:8
    
    C1从队列中获取了C1:P1:7P1把值P1:4放入了队列
    
    C1从队列中获取了C1:P1:0P1把值P1:7放入了队列
    
    C1从队列中获取了C1:P1:3P1把值P1:2放入了队列P2把值P2:5放入了队列
    
    
    C1从队列中获取了C1:P1:4P1把值P1:6放入了队列P2把值P2:6放入了队列
    
    
    C1从队列中获取了C1:P1:7P1把值P1:10放入了队列P2把值P2:5放入了队列
    
    
    C1从队列中获取了C1:P1:2P1把值P1:4放入了队列P2把值P2:5放入了队列
    
    
    C1从队列中获取了C1:P1:6队列满了,生产者等待P2把值P2:2放入了队列
    
    
    C1从队列中获取了C1:P1:10队列满了,生产者等待P2把值P2:9放入了队列
    
    
    C1从队列中获取了C1:P1:4P2把值P2:10放入了队列
    
    队列空了,消费者等待P2把值P2:0放入了队列
    
    P2把值P2:4放入了队列
    P2把值P2:10放入了队列
    队列满了,生产者等待


## queue模块说明

队列类型 

+ queue.Queue(maxsize) 先进先出队列,maxsize是队列长度,其值为非正数时是无限循环队列

+ queue.LifoQueue(maxsize) 后进先出队列,也就是栈
+ queue.PriorityQueue(maxsize) 优先级队列


支持方法

+ qsize() 返回近似队列大小,,用近似二字因为当该值大于0时不能保证并发执行的时候get(),put()方法不被阻塞
+ empty() 判断是否为空,空返回True否则返回False
+ full() 当设定了队列大小的时候,如果队列满了则返回True,否则False
+ put(item[,block[,timeout]]) 向队列添加元素
    + 当block设置为False时队列满则抛出异常
    + 当block为True,timeout为None时则会等待直到有空位
    + 当block为True,timeout不为None时则根据设定的时间判断是否等待,超时了就抛出错误
+ put_nowait(item) 相当于put(item,False)
+ get([,block[,timeout]) 从队列中取出元素,
    + 当block设置为False时队列空则抛出异常
    + 当block为True,timeout为None时则会等待直到有+元素
    + 当block为True,timeout不为None时则根据设定的时间判断是否等待,超时了就抛出错误
+ get_nowait() 等价于get(False)
+ task_done() 发送信号表明入列任务已经完成,常在消费者线程里使用
+ join() 阻塞直到队列中所有元素处理完

Queue是线程安全的,而且支持in操作,因此用它的时候不用考虑锁的问题
