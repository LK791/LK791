[# 凯子哥爱搞钱
111
](https://github.com/LK791/finhack-)






# b站视频 下载
https://github.com/iuroc/bilidown
很不错 牛逼 






# 量化

https://github.com/FinHackCN/finhack

这个人搞量化的的，瞅着很不错



---


# MyTT
https://github.com/LK791/MyTT

真牛逼 ，，直接复刻通达信指标


---

# mootdx 
这个库真牛逼  ，直接读取通达信数据
库链接 https://github.com/LK791/mootdx
```python

from mootdx.reader import Reader
# market 参数 std 为标准市场(就是股票), ext 为扩展市场(期货，黄金等)
# tdxdir 是通达信的数据目录, 根据自己的情况修改
reader = Reader.factory(market='std', tdxdir='C:/new_tdx')
# 读取日线数据
print(     reader.daily(symbol='873001')    )
exit()

# 先通达信库客户端，下载好了日线数据，然后使用这个库能直接读取day文件，，，超级无敌好用  
# 这个配置好了代码块，使用 mootdx，
# 还有超级多的功能，还能读取实时数据，有点厉害了

